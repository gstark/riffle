import { describe, expect, it } from "vitest";
import type { Label } from "../shared/storage.ts";
import { BadRequestError, exactQuery, SearchBodySchema, type Filters } from "./request.ts";

const labels: Label[] = [
  { id: "INBOX", name: "INBOX", type: "system" },
  { id: "SPAM", name: "SPAM", type: "system" },
  { id: "Label_7", name: "Receipts", type: "user" },
];

const filters: Filters = {
  text: "insurance renewal",
  from: ["acme"],
  to: [],
  after: "2024-01-01",
  before: null,
  labels: ["Receipts"],
  includeSpamTrash: false,
  hasAttachment: true,
  sort: "relevance",
};

describe("SearchBodySchema", () => {
  it("reads a text search with the default limit", () => {
    expect(SearchBodySchema.parse({ q: "tax" })).toEqual({ q: "tax", limit: 20 });
  });

  it("reads a filter search", () => {
    expect(SearchBodySchema.parse({ filters, limit: 50 })).toEqual({ filters, limit: 50 });
  });

  it.each<[string, unknown]>([
    ["both q and filters", { q: "tax", filters }],
    ["neither q nor filters", { limit: 5 }],
    ["a missing filter field", { filters: { ...filters, sort: undefined } }],
    ["a bad date", { filters: { ...filters, after: "2024-13-01" } }],
    ["after equal to before", { filters: { ...filters, after: "2024-01-01", before: "2024-01-01" } }],
    ["after later than before", { filters: { ...filters, after: "2024-02-01", before: "2024-01-01" } }],
    ["11 senders", { filters: { ...filters, from: Array.from({ length: 11 }, (_, i) => `s${i}`) } }],
    ["an empty sender", { filters: { ...filters, from: [" "] } }],
    ["a limit above 50", { q: "tax", limit: 51 }],
  ])("rejects %s", (_, body) => {
    expect(SearchBodySchema.safeParse(body).success).toBe(false);
  });
});

describe("exactQuery", () => {
  it("uses the filters as they are, with label IDs", () => {
    expect(exactQuery(filters, labels)).toEqual({ ...filters, labelIds: ["Label_7"], source: "filters" });
  });

  it.each<[string]>([["Bills"], ["SPAM"]])("rejects the label %s", (name) => {
    expect(() => exactQuery({ ...filters, labels: [name] }, labels)).toThrow(new BadRequestError(`Unknown label: ${name}`));
  });
});
