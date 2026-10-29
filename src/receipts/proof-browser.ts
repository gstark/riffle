// The browser of the proofs Lambda: an Amazon Bedrock AgentCore Browser session that Playwright drives over CDP.
// Chromium runs in AgentCore, not in the Lambda. Each link gets a new browser context, so no cookies are shared.
// The session starts at the first use, so a run with an empty queue does not pay for one.

import {
  BedrockAgentCoreClient,
  StartBrowserSessionCommand,
  StopBrowserSessionCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { Sha256 } from "@aws-crypto/sha256-js";
import { SignatureV4 } from "@smithy/signature-v4";
import { chromium, type Browser, type BrowserContext, type Download, type Page } from "playwright-core";
import type { Visit } from "./proof.ts";
import type { ProofBrowser } from "./proof-pass.ts";

const NAVIGATION_TIMEOUT_MS = 30_000;
/** Wait for scripts that load the receipt after the load event. */
const IDLE_TIMEOUT_MS = 8_000;
const PDF_OPTIONS = { format: "Letter", printBackground: true } as const;
/** page.pdf and newContext have no timeout, and a page can freeze the browser. */
const USE_DEADLINE_MS = 90_000;

const isPdf = (bytes: Uint8Array) => Buffer.from(bytes.subarray(0, 5)).toString("latin1") === "%PDF-";
const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

export interface ProofBrowserOptions {
  region: string;
  /** ID of the AgentCore browser (infra/proofs.tf) */
  browserId: string;
  /** AgentCore stops the session after this time. It must be longer than the run. */
  sessionSeconds: number;
}

/** The browser crashed, froze, or closed the connection during one use. */
class BrowserLost extends Error {}

interface Session {
  browser: Browser;
  stop(): Promise<void>;
}

async function startSession({ region, browserId, sessionSeconds }: ProofBrowserOptions): Promise<Session> {
  const client = new BedrockAgentCoreClient({ region });
  const { sessionId } = await client.send(
    new StartBrowserSessionCommand({
      browserIdentifier: browserId,
      name: "riffle-proofs",
      sessionTimeoutSeconds: sessionSeconds,
    }),
  );
  const stop = async () => {
    await client.send(new StopBrowserSessionCommand({ browserIdentifier: browserId, sessionId }));
  };
  try {
    // The automation stream is a WebSocket that needs a SigV4 signature in its headers.
    const host = `bedrock-agentcore.${region}.amazonaws.com`;
    const path = `/browser-streams/${browserId}/sessions/${sessionId}/automation`;
    const signer = new SignatureV4({
      service: "bedrock-agentcore",
      region,
      credentials: client.config.credentials,
      sha256: Sha256,
    });
    const { headers } = await signer.sign({ method: "GET", protocol: "wss:", hostname: host, path, headers: { host } });
    return { browser: await chromium.connectOverCDP(`wss://${host}${path}`, { headers }), stop };
  } catch (error) {
    await stop();
    throw error;
  }
}

/** The bytes of a PDF link. Chrome shows a PDF in its viewer, so the page itself is not the file. */
async function pdfOf(page: Page): Promise<Uint8Array> {
  const base64 = await page.evaluate(async () => {
    const bytes = new Uint8Array(await (await fetch(location.href, { credentials: "include" })).arrayBuffer());
    let text = "";
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(text);
  });
  return Buffer.from(base64, "base64");
}

/** A link that starts a download. The file is on the AgentCore machine, so get it again with the cookies of the context. */
async function downloadOf(context: BrowserContext, file: Download): Promise<Visit> {
  const response = await context.request.get(file.url(), { timeout: NAVIGATION_TIMEOUT_MS });
  const bytes = await response.body();
  if (!isPdf(bytes)) return { ok: false, error: `The link gave a file that is not a PDF: ${file.suggestedFilename()}` };
  return {
    ok: true,
    status: response.status(),
    finalUrl: response.url(),
    pdf: bytes,
    download: true,
    hasPasswordField: false,
    text: "",
  };
}

export function openProofBrowser(options: ProofBrowserOptions): ProofBrowser & { close(): Promise<void> } {
  let session: Promise<Session> | null = null;

  /** The connected browser. AgentCore can close the connection, so a lost session is replaced by a new one. */
  async function browser(): Promise<Browser> {
    const pending = (session ??= startSession(options));
    const current = await pending.catch((error: unknown) => {
      // A session that failed to start must not stay cached. The next use tries a new one.
      if (session === pending) session = null;
      throw error;
    });
    if (current.browser.isConnected()) return current.browser;
    if (session === pending) {
      session = startSession(options);
      current.stop().catch(() => {});
    }
    return (await session).browser;
  }

  /**
   * One use of the browser with a deadline. A page can crash or freeze the AgentCore browser. Then the connection
   * is closed, so the next use starts a new session.
   */
  async function use<T>(work: (browser: Browser) => Promise<T>): Promise<T> {
    const current = await browser();
    let timer: NodeJS.Timeout | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error(`No answer from the browser in ${USE_DEADLINE_MS / 1000} s`)),
        USE_DEADLINE_MS,
      );
    });
    const working = work(current);
    working.catch(() => {});
    try {
      return await Promise.race([working, deadline]);
    } catch (error) {
      await current.close().catch(() => {});
      throw new BrowserLost(errorText(error));
    } finally {
      clearTimeout(timer);
    }
  }

  /** Try again once on a new session: AgentCore can also close a connection that no page caused. */
  async function twice<T>(work: (browser: Browser) => Promise<T>): Promise<T> {
    try {
      return await use(work);
    } catch (error) {
      if (!(error instanceof BrowserLost)) throw error;
      return await use(work);
    }
  }

  /** Throws only when the browser is lost. A failure of the page itself is a Visit. */
  async function visitOnce(current: Browser, url: string): Promise<Visit> {
    const context = await current.newContext({ acceptDownloads: true });
    try {
      const page = await context.newPage();
      // A link to a PDF file with "Content-Disposition: attachment" starts a download, and the navigation fails.
      const download = page
        .waitForEvent("download", { timeout: NAVIGATION_TIMEOUT_MS })
        .catch((): Download | null => null);
      let response;
      try {
        response = await page.goto(url, { waitUntil: "load", timeout: NAVIGATION_TIMEOUT_MS });
      } catch (error) {
        const file = await download;
        if (!file) throw error;
        return await downloadOf(context, file);
      }
      const status = response?.status() ?? null;
      if (response?.headers()["content-type"]?.includes("application/pdf")) {
        const pdf = await pdfOf(page);
        if (isPdf(pdf)) {
          return { ok: true, status, finalUrl: page.url(), pdf, download: true, hasPasswordField: false, text: "" };
        }
      }
      await page.waitForLoadState("networkidle", { timeout: IDLE_TIMEOUT_MS }).catch(() => {});
      return {
        ok: true,
        status,
        finalUrl: page.url(),
        pdf: await page.pdf(PDF_OPTIONS),
        download: false,
        hasPasswordField: (await page.locator('input[type="password"]').count()) > 0,
        text: await page.innerText("body").catch(() => ""),
      };
    } catch (error) {
      if (!current.isConnected()) throw error;
      return { ok: false, error: errorText(error) };
    } finally {
      await context.close().catch(() => {});
    }
  }

  async function visit(url: string): Promise<Visit> {
    try {
      return await twice((current) => visitOnce(current, url));
    } catch (error) {
      // The page lost the browser two times. It is a fact about the link, so record it and go on.
      if (!(error instanceof BrowserLost)) throw error;
      return { ok: false, error: `The page closed or froze the browser two times: ${errorText(error)}` };
    }
  }

  async function renderOnce(current: Browser, html: string, images: boolean): Promise<Uint8Array> {
    // Email HTML must not run scripts. Remote images still load, as in a mail app.
    const context = await current.newContext({ javaScriptEnabled: false });
    try {
      const page = await context.newPage();
      if (!images)
        await page.route("**/*", (route) =>
          route.request().resourceType() === "image" ? route.abort() : route.continue(),
        );
      // A slow remote image must not stop the PDF. After the timeout, the page prints without it.
      await page.setContent(html, { waitUntil: "load", timeout: IDLE_TIMEOUT_MS }).catch(() => {});
      return await page.pdf(PDF_OPTIONS);
    } finally {
      await context.close().catch(() => {});
    }
  }

  async function renderPage(html: string): Promise<Uint8Array> {
    try {
      return await twice((current) => renderOnce(current, html, true));
    } catch (error) {
      if (!(error instanceof BrowserLost)) throw error;
      // Chrome puts each image in the PDF at full size. A PDF of about 10 MB closes the AgentCore connection,
      // so print the email without its remote images. A failure here fails the message, and the queue tries it again.
      return await use((current) => renderOnce(current, html, false));
    }
  }

  async function close() {
    // A session that failed to start has nothing to stop.
    const started = await session?.catch(() => null);
    if (!started) return;
    await started.browser.close().catch(() => {});
    await started.stop();
  }

  return { visit, renderPage, close };
}
