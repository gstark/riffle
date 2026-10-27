import * as lancedb from "@lancedb/lancedb";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Label } from "../shared/storage.ts";
import { meta } from "../sync/test-fakes.ts";
import type { ModelOutput, ReadQuery } from "./parse-query.ts";
import { buildRow } from "./row.ts";
import { BadRequestError, type Filters } from "./request.ts";
import { createSearch, labelList } from "./service.ts";
import { ensureIndexes, openOrCreateTable, upsertRows } from "./table.ts";
import { fakeEmbed } from "./test-fakes.ts";

const labels: Label[] = [
  { id: "INBOX", name: "INBOX", type: "system" },
  { id: "Label_7", name: "Receipts", type: "user" },
];

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "search-service-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

async function setup(read: ReadQuery) {
  const table = await openOrCreateTable(dir);
  const message = async (id: string, from: string, subject: string, body: string, labelIds: string[]) =>
    buildRow(meta(id, labelIds), { from, to: "me@example.com", subject, attachments: [], body }, await fakeEmbed(`${subject} ${body}`));
  await upsertRows(table, [
    await message("a", "orders@amazon.com", "Your order", "Invoice for your order", ["INBOX", "Label_7"]),
    await message("b", "jane@example.com", "Lunch", "Pizza on Friday", ["INBOX"]),
  ]);
  await ensureIndexes(table, () => {});
  return createSearch({
    table,
    reranker: await lancedb.rerankers.RRFReranker.create(),
    embed: fakeEmbed,
    read,
    getLabels: async () => labels,
    gmailUser: "me@example.com",
    timeZone: "America/New_York",
    now: () => new Date("2026-10-22T12:00:00Z"),
    log: () => {},
  });
}

const reading: ModelOutput = {
  text: "invoice",
  from: ["amazon"],
  to: [],
  after: null,
  before: null,
  labels: [],
  includeSpamTrash: false,
  hasAttachment: null,
  sort: "relevance",
};

describe("createSearch", () => {
  it("parses the query, searches, and returns Gmail links with label names", async () => {
    const search = await setup(async () => reading);

    const response = await search({ q: "invoices from amazon" }, 20);

    expect(response.query).toEqual({ ...reading, source: "claude" });
    expect(response.results).toEqual([
      {
        id: "a",
        threadId: "t-a",
        date: "2024-03-09T00:00:00.000Z",
        from: "orders@amazon.com",
        subject: "Your order",
        snippet: "Invoice for your order",
        labels: ["INBOX", "Receipts"],
        hasAttachment: false,
        gmailUrl: "https://mail.google.com/mail/?authuser=me%40example.com#all/t-a",
      },
    ]);
    expect(response.timings).toEqual({
      parseMs: expect.any(Number),
      embedMs: expect.any(Number),
      searchMs: expect.any(Number),
    });
  });

  it("keeps a quoted phrase out of Claude's reading and searches for it as written", async () => {
    const queries: string[] = [];
    const search = await setup(async ({ query }) => {
      queries.push(query);
      return { ...reading, text: "", from: ["amazon"] };
    });

    const response = await search({ q: '"your ORDER" from amazon' }, 20);

    expect(queries).toEqual(["from amazon"]);
    expect(response.query).toEqual({ ...reading, text: '"your ORDER"', from: ["amazon"], source: "claude" });
    expect(response.results.map((result) => result.id)).toEqual(["a"]);
  });

  it("does not call Claude when the query is only a quoted phrase", async () => {
    const search = await setup(async () => {
      throw new Error("Claude must not be called");
    });

    const response = await search({ q: '"pizza on friday"' }, 20);

    expect(response.query).toEqual({ ...reading, text: '"pizza on friday"', from: [], source: "filters" });
    expect(response.results.map((result) => result.id)).toEqual(["b"]);
  });

  it("searches the plain text when the parser fails", async () => {
    const search = await setup(async () => {
      throw new Error("timeout");
    });

    const response = await search({ q: "pizza" }, 20);

    expect(response.query.source).toBe("plain");
    expect(response.results.map((result) => result.id)).toContain("b");
  });
});

const filters: Filters = {
  text: "",
  from: [],
  to: [],
  after: null,
  before: null,
  labels: ["Receipts"],
  includeSpamTrash: false,
  hasAttachment: null,
  sort: "relevance",
};

describe("createSearch with exact filters", () => {
  const noClaude: ReadQuery = async () => {
    throw new Error("Claude must not be called");
  };

  it("uses the filters without Claude", async () => {
    const search = await setup(noClaude);

    const response = await search({ filters: { ...filters, text: "invoice" } }, 20);

    expect(response.query).toEqual({ ...filters, text: "invoice", source: "filters" });
    expect(response.results.map((result) => result.id)).toEqual(["a"]);
  });

  it("holds the results to a quoted phrase in the text", async () => {
    const search = await setup(noClaude);

    const response = await search({ filters: { ...filters, text: '"pizza invoice"', labels: [] } }, 20);

    expect(response.results).toEqual([]);
    expect((await search({ filters: { ...filters, text: '"your order"', labels: [] } }, 20)).results.map((r) => r.id)).toEqual(["a"]);
  });

  it("sorts by newest when there is no text to rank against", async () => {
    const search = await setup(noClaude);

    const response = await search({ filters }, 20);

    expect(response.query.sort).toBe("newest");
    expect(response.results.map((result) => result.id)).toEqual(["a"]);
  });

  it("rejects an unknown label", async () => {
    const search = await setup(noClaude);

    await expect(search({ filters: { ...filters, labels: ["Bills"] } }, 20)).rejects.toThrow(BadRequestError);
  });
});

describe("labelList", () => {
  it("returns the names and types, sorted by name", () => {
    expect(labelList([...labels].reverse())).toEqual([
      { name: "INBOX", type: "system" },
      { name: "Receipts", type: "user" },
    ]);
  });
});
