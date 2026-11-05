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
  const logs: string[] = [];
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
      result: async (page) => {
        results.push(page);
        return { fidelity: "merchant_page" };
      },
    },
    receipts: {
      list: async () => [],
      pdfUrl: async (id, which) => {
        if (id === "missing") throw new BadRequestError("Receipt missing has no PDF");
        return `https://archive.example.com/${id}${which === "email" ? "-email" : ""}.pdf`;
      },
    },
    log: (line) => logs.push(line),
  });
  return { api, searches, results, logs };
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

  it("lists the receipts", async () => {
    const { api } = setup();

    const result = await api(event("GET", "/receipts"));

    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ receipts: [] });
  });

  it("gives a PDF link of a receipt", async () => {
    const { api } = setup();

    const result = await api(event("POST", "/receipts/pdf", { body: '{"id":"m1:0"}' }));

    expect(JSON.parse(result.body)).toEqual({ url: "https://archive.example.com/m1:0.pdf" });
  });

  it("gives the email PDF link of a receipt", async () => {
    const { api } = setup();

    const result = await api(event("POST", "/receipts/pdf", { body: '{"id":"m1:0","which":"email"}' }));

    expect(JSON.parse(result.body)).toEqual({ url: "https://archive.example.com/m1:0-email.pdf" });
  });

  it.each<[string]>([['{"id":"missing"}'], ["{}"], ['{"id":"m1:0","which":"signed"}']])("rejects the PDF request %s", async (body) => {
    const { api } = setup();

    const result = await api(event("POST", "/receipts/pdf", { body }));

    expect(result.statusCode).toBe(400);
  });

  it("records a page result with its PDF", async () => {
    const { api, results } = setup();
    const page = { id: "m1:0", finalUrl: "https://example.com/", status: null, hasPasswordField: false, text: "Total" };
    const pdf = Buffer.from("%PDF-1.4").toString("base64");

    const result = await api(event("POST", "/proofs/result", { body: JSON.stringify({ ...page, pdf }) }));

    expect(JSON.parse(result.body)).toEqual({ fidelity: "merchant_page" });
    expect(results).toEqual([{ ...page, pdf: new Uint8Array(Buffer.from("%PDF-1.4")) }]);
  });

  it("logs each page result without the query of the address", async () => {
    const { api, logs } = setup();
    const page = { id: "m1:0", finalUrl: "https://auth.rev.com/login?returnUrl=x", status: 200, hasPasswordField: true, text: "Sign in" };

    await api(event("POST", "/proofs/result", { body: JSON.stringify(page) }));

    expect(logs).toEqual([
      "Proof result m1:0: merchant_page at auth.rev.com/login, HTTP 200, password field true, 7 characters of text, no PDF",
    ]);
  });

  it("logs a rejected request", async () => {
    const { api, logs } = setup();

    await api(event("POST", "/receipts/pdf", { body: '{"id":"missing"}' }));

    expect(logs).toEqual(["Request rejected: POST /receipts/pdf: Receipt missing has no PDF"]);
  });

  it("records a page result without a PDF", async () => {
    const { api, results } = setup();
    const page = { id: "m1:0", finalUrl: "https://example.com/", status: null, hasPasswordField: false, text: "Help" };

    await api(event("POST", "/proofs/result", { body: JSON.stringify(page) }));

    expect(results).toEqual([{ ...page, pdf: null }]);
  });

  it.each<[string, string]>([
    ["/proofs/result", '{"id":"m1:0"}'],
    ["/proofs/result", '{"id":"m1:0","finalUrl":"x","status":1.5,"hasPasswordField":false,"text":"","pdf":"JVBERg=="}'],
    ["/proofs/result", '{"id":"m1:0","finalUrl":"x","status":null,"hasPasswordField":false,"text":"","pdf":"not base64!"}'],
  ])("rejects the body of %s: %s", async (path, body) => {
    const { api, results } = setup();

    const result = await api(event("POST", path, { body }));

    expect(result.statusCode).toBe(400);
    expect(results).toEqual([]);
  });
});
