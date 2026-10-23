// HTTP routes of the search Function URL.

import { z } from "zod";
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
  log: (message: string) => void;
}

const json = (statusCode: number, value: unknown): FunctionUrlResult => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(value),
});

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
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
        const raw = event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString() : (event.body ?? "");
        const request = SearchBodySchema.safeParse(parseJson(raw));
        if (!request.success) {
          return json(400, {
            error: `The body must be {"q": string} or {"filters": {...}}, with an optional "limit". ${z.prettifyError(request.error)}`,
          });
        }
        const { limit, ...input } = request.data;
        return json(200, await deps.search(input, limit));
      }
      return json(404, { error: "Not found" });
    } catch (error) {
      if (error instanceof BadRequestError) return json(400, { error: error.message });
      deps.log(`Request failed: ${error instanceof Error ? error.message : String(error)}`);
      return json(500, { error: "Internal error" });
    }
  };
}
