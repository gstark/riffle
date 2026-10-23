import { describe, expect, it } from "vitest";
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
  const api = createApi({
    getToken: async () => "secret",
    search: async (input, limit) => {
      if (fail) throw fail;
      searches.push([input, limit]);
      return { echo: input };
    },
    labels: async () => [{ name: "INBOX", type: "system" }],
    health: async () => new Date("2026-10-23T14:42:00.000Z"),
    log: () => {},
  });
  return { api, searches };
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
});
