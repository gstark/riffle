// HTTP routes of the search Function URL.

import { z } from "zod";
import type { Receipts } from "../receipts/browse.ts";
import type { SignedInProofs } from "../receipts/signed-in.ts";
import { isAuthorized } from "./auth.ts";
import { BadRequestError, SearchBodySchema, type SearchInput } from "./request.ts";

/** The fields of a Lambda Function URL event that the API uses. */
export interface FunctionUrlEvent {
  rawPath: string;
  /** Lambda gives header names in lower case. */
  headers?: Record<string, string | undefined>;
  body?: string;
  isBase64Encoded?: boolean;
  requestContext: { http: { method: string } };
}

export interface FunctionUrlResult {
  statusCode: number;
  headers?: Record<string, string>;
  body: string;
}

export interface ApiDeps {
  getToken: () => Promise<string>;
  /** Throws BadRequestError when the request names something that does not exist. */
  search: (input: SearchInput, limit: number) => Promise<unknown>;
  labels: () => Promise<unknown[]>;
  /**
   * Prepares the table and clients, so the first search after a cold start is fast.
   * Returns the date of the newest message in the index, or null when the index is empty.
   */
  health: () => Promise<Date | null>;
  /** Routes under /proofs, for the proofs that the Riffle app makes with a sign-in. */
  proofs: SignedInProofs;
  /** Routes under /receipts, for the Receipts window of the Riffle app. */
  receipts: Pick<Receipts, "list" | "pdfUrl">;
  log: (message: string) => void;
}

const json = (statusCode: number, value: unknown): FunctionUrlResult => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(value),
});

const PdfBodySchema = z.strictObject({ id: z.string().min(1), which: z.enum(["best", "email"]).default("best") });

const ResultBodySchema = z.strictObject({
  id: z.string().min(1),
  finalUrl: z.string(),
  status: z.int().nullable(),
  hasPasswordField: z.boolean(),
  text: z.string(),
  /** The printed page, base64. Missing when the page does not show the receipt. */
  pdf: z
    .base64()
    .min(1)
    .transform((pdf) => new Uint8Array(Buffer.from(pdf, "base64")))
    .nullable()
    .default(null),
});

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** The JSON body of the request, or undefined when it is not JSON. */
function body(event: FunctionUrlEvent): unknown {
  return parseJson(event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : (event.body ?? ""));
}

/** The host and the path of a page. The query can contain a token, so the log does not get it. */
function address(url: string): string {
  try {
    const { host, pathname } = new URL(url);
    return host + pathname;
  } catch {
    return "an address that is not valid";
  }
}

export function createApi(deps: ApiDeps): (event: FunctionUrlEvent) => Promise<FunctionUrlResult> {
  return async (event) => {
    if (!isAuthorized(event.headers?.authorization, await deps.getToken())) return { statusCode: 401, body: "" };

    const route = `${event.requestContext.http.method} ${event.rawPath}`;
    try {
      if (route === "GET /health") {
        const newest = await deps.health();
        return json(200, { ok: true, newestMessageAt: newest?.toISOString() ?? null });
      }
      if (route === "GET /labels") {
        return json(200, { labels: await deps.labels() });
      }
      if (route === "POST /search") {
        const request = SearchBodySchema.safeParse(body(event));
        if (!request.success) {
          return json(400, {
            error: `The body must be {"q": string} or {"filters": {...}}, with an optional "limit". ${z.prettifyError(request.error)}`,
          });
        }
        const { limit, ...input } = request.data;
        return json(200, await deps.search(input, limit));
      }
      if (route === "GET /proofs/pending") {
        return json(200, { sites: await deps.proofs.pending() });
      }
      if (route === "POST /proofs/result") {
        const request = ResultBodySchema.safeParse(body(event));
        if (!request.success) {
          return json(400, {
            error: `The body must be {"id", "finalUrl", "status", "hasPasswordField", "text", "pdf"?}. ${z.prettifyError(request.error)}`,
          });
        }
        const page = request.data;
        const result = await deps.proofs.result(page);
        const pdf = page.pdf ? `a PDF of ${page.pdf.length} bytes` : "no PDF";
        deps.log(
          `Proof result ${page.id}: ${result.fidelity} at ${address(page.finalUrl)}, HTTP ${page.status ?? "unknown"}, ` +
            `password field ${page.hasPasswordField}, ${page.text.length} characters of text, ${pdf}`,
        );
        return json(200, result);
      }
      if (route === "GET /receipts") {
        return json(200, { receipts: await deps.receipts.list() });
      }
      if (route === "POST /receipts/pdf") {
        const request = PdfBodySchema.safeParse(body(event));
        if (!request.success) {
          return json(400, { error: `The body must be {"id": string, "which"?: "best" | "email"}. ${z.prettifyError(request.error)}` });
        }
        return json(200, { url: await deps.receipts.pdfUrl(request.data.id, request.data.which) });
      }
      return json(404, { error: "Not found" });
    } catch (error) {
      if (error instanceof BadRequestError) {
        deps.log(`Request rejected: ${route}: ${error.message}`);
        return json(400, { error: error.message });
      }
      deps.log(`Request failed: ${error instanceof Error ? error.message : String(error)}`);
      return json(500, { error: "Internal error" });
    }
  };
}
