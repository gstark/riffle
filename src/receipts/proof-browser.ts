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

const isPdf = (bytes: Uint8Array) => Buffer.from(bytes.subarray(0, 5)).toString("latin1") === "%PDF-";
const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

export interface ProofBrowserOptions {
  region: string;
  /** ID of the AgentCore browser (infra/proofs.tf) */
  browserId: string;
  /** AgentCore stops the session after this time. It must be longer than the run. */
  sessionSeconds: number;
}

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
    const current = await pending;
    if (current.browser.isConnected()) return current.browser;
    if (session === pending) {
      session = startSession(options);
      current.stop().catch(() => {});
    }
    return (await session).browser;
  }

  async function visit(url: string): Promise<Visit> {
    const context = await (await browser()).newContext({ acceptDownloads: true });
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
      // A lost connection is not a fact about the link. Throw, so the message is tried again.
      if (!context.browser()?.isConnected()) throw error;
      return { ok: false, error: errorText(error) };
    } finally {
      await context.close().catch(() => {});
    }
  }

  async function renderPage(html: string): Promise<Uint8Array> {
    // Email HTML must not run scripts. Remote images still load, as in a mail app.
    const context = await (await browser()).newContext({ javaScriptEnabled: false });
    try {
      const page = await context.newPage();
      // A slow remote image must not stop the PDF. After the timeout, the page prints without it.
      await page.setContent(html, { waitUntil: "load", timeout: IDLE_TIMEOUT_MS }).catch(() => {});
      return await page.pdf(PDF_OPTIONS);
    } finally {
      await context.close().catch(() => {});
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
