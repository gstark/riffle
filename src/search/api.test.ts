import { describe, expect, it } from "vitest";
import type { PageResult } from "../receipts/signed-in.ts";
import { createApi, type FunctionUrlEvent } from "./api.ts";
import { BadRequestError, type Filters, type SearchInput } from "./request.ts";

interface EventOptions {
  /** null sends no Authorization header. */
  token?: string | null;
  body?: string;
  base64?: boolean;
}

function event(method: string, path: string, { token = "secret", body, base64 = false }: EventOptions = {}): FunctionUrlEvent {
  return {
    rawPath: path,
    headers: token === null ? {} : { authorization: `Bearer ${token}` },
    body: base64 && body !== undefined ? Buffer.from(body).toString("base64") : body,
    isBase64Encoded: base64,
    requestContext: { http: { method } },
  };
}

/** SHA-256 of an empty file, in base64. */
const SHA256 = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=";

const filters: Filters = {
  text: "renewal",
  from: ["acme"],
  to: [],
  after: null,
  before: null,
  labels: [],
  includeSpamTrash: false,
  hasAttachment: null,
  sort: "relevance",
};

function setup({ fail }: { fail?: Error } = {}) {
  const searches: [SearchInput, number][] = [];
  const results: PageResult[] = [];
  const api = createApi({
    getToken: async () => "secret",
    search: async (input, limit) => {
      if (fail) throw fail;
      searches.push([input, limit]);
      return { echo: input };
    },
    labels: async () => [{ name: "INBOX", type: "system" }],
    health: async () => new Date("2026-10-23T14:42:00.000Z"),
    proofs: {
      pending: async () => [{ site: "amazon.com", merchant: "Amazon", receipts: [] }],
      upload: async (id, sha256) => ({ url: `https://s3.example.com/${id}?${sha256}`, key: `proofs/${id}.pdf` }),
      result: async (page) => {
        results.push(page);
        return { fidelity: "merchant_page" };
      },
    },
    log: () => {},
  });
  return { api, searches, results };
}

describe("createApi", () => {
  it.each<[string | null]>([[null], ["wrong"]])("rejects the token %j", async (token) => {
    const { api, searches } = setup();

    const result = await api(event("POST", "/search", { token, body: '{"q":"tax"}' }));

    expect(result).toEqual({ statusCode: 401, body: "" });
    expect(searches).toEqual([]);
  });

  it("searches with the default limit", async () => {
    const { api, searches } = setup();

    const result = await api(event("POST", "/search", { body: '{"q":"tax"}' }));

    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ echo: { q: "tax" } });
    expect(searches).toEqual([[{ q: "tax" }, 20]]);
  });

  it("reads a base64 body", async () => {
    const { api, searches } = setup();

    await api(event("POST", "/search", { body: '{"q":"tax","limit":5}', base64: true }));

    expect(searches).toEqual([[{ q: "tax" }, 5]]);
  });

  it("searches with exact filters", async () => {
    const { api, searches } = setup();

    await api(event("POST", "/search", { body: JSON.stringify({ filters, limit: 50 }) }));

    expect(searches).toEqual([[{ filters }, 50]]);
  });

  it.each<[string]>([['{"q":""}'], ['{"q":"x","limit":51}'], ["not json"], [JSON.stringify({ q: "x", filters })]])(
    "rejects the body %s with a reason",
    async (body) => {
      const { api, searches } = setup();

      const result = await api(event("POST", "/search", { body }));

      expect(result.statusCode).toBe(400);
      expect(JSON.parse(result.body)).toEqual({ error: expect.any(String) });
      expect(searches).toEqual([]);
    },
  );

  it("returns 400 with the message of a BadRequestError", async () => {
    const { api } = setup({ fail: new BadRequestError("Unknown label: Bills") });

    const result = await api(event("POST", "/search", { body: JSON.stringify({ filters }) }));

    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body)).toEqual({ error: "Unknown label: Bills" });
  });

  it("lists the labels", async () => {
    const { api } = setup();

    const result = await api(event("GET", "/labels"));

    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ labels: [{ name: "INBOX", type: "system" }] });
  });

  it("does not list the labels without the token", async () => {
    const { api } = setup();

    expect((await api(event("GET", "/labels", { token: null }))).statusCode).toBe(401);
  });

  it("answers the health check", async () => {
    const { api } = setup();

    const result = await api(event("GET", "/health"));

    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ ok: true, newestMessageAt: "2026-10-23T14:42:00.000Z" });
  });

  it("returns 404 for other routes", async () => {
    const { api } = setup();

    expect((await api(event("GET", "/search"))).statusCode).toBe(404);
  });

  it("returns 500 without details when the search fails", async () => {
    const { api } = setup({ fail: new Error("boom") });

    const result = await api(event("POST", "/search", { body: '{"q":"tax"}' }));

    expect(result.statusCode).toBe(500);
    expect(JSON.parse(result.body)).toEqual({ error: "Internal error" });
  });

  it("lists the pending signed-in proofs", async () => {
    const { api } = setup();

    const result = await api(event("GET", "/proofs/pending"));

    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ sites: [{ site: "amazon.com", merchant: "Amazon", receipts: [] }] });
  });

  it("gives an upload URL", async () => {
    const { api } = setup();

    const body = JSON.stringify({ id: "m1:0", sha256: SHA256 });
    const result = await api(event("POST", "/proofs/upload", { body }));

    expect(JSON.parse(result.body)).toEqual({ url: `https://s3.example.com/m1:0?${SHA256}`, key: "proofs/m1:0.pdf" });
  });

  it("records a page result", async () => {
    const { api, results } = setup();
    const page = { id: "m1:0", finalUrl: "https://example.com/", status: null, hasPasswordField: false, text: "Total" };

    const result = await api(event("POST", "/proofs/result", { body: JSON.stringify(page) }));

    expect(JSON.parse(result.body)).toEqual({ fidelity: "merchant_page" });
    expect(results).toEqual([page]);
  });

  it.each<[string, string]>([
    ["/proofs/upload", "{}"],
    ["/proofs/upload", '{"id":"m1:0","sha256":"short"}'],
    ["/proofs/result", '{"id":"m1:0"}'],
    ["/proofs/result", '{"id":"m1:0","finalUrl":"x","status":1.5,"hasPasswordField":false,"text":""}'],
  ])("rejects the body of %s: %s", async (path, body) => {
    const { api, results } = setup();

    const result = await api(event("POST", path, { body }));

    expect(result.statusCode).toBe(400);
    expect(results).toEqual([]);
  });
});
