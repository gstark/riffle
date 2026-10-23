import * as lancedb from "@lancedb/lancedb";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { buildRow } from "./row.ts";
import { newestMessageDate, searchTable, type SearchRequest } from "./search.ts";
import { ensureIndexes, openOrCreateTable, upsertRows } from "./table.ts";
import { fakeEmbed } from "./test-fakes.ts";
import { buildWhere } from "./where.ts";

const TZ = "America/New_York";
const noFilter = buildWhere(
  { from: [], to: [], after: null, before: null, labelIds: [], includeSpamTrash: false, hasAttachment: null },
  TZ,
);

let dir: string;
let table: lancedb.Table;
let reranker: lancedb.rerankers.RRFReranker;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "search-query-"));
  table = await openOrCreateTable(dir);
  reranker = await lancedb.rerankers.RRFReranker.create();
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

interface Message {
  id: string;
  thread?: string;
  from?: string;
  subject?: string;
  body?: string;
  date?: string;
  labels?: string[];
  deleted?: boolean;
}

async function add(messages: Message[]) {
  const rows = await Promise.all(
    messages.map(async ({ id, thread = id, from = "jane@example.com", subject = "Hello", body = "Hello there", date = "2024-03-09T00:00:00.000Z", labels = ["INBOX"], deleted = false }) => {
      const fields = { from, to: "me@example.com", subject, attachments: [], body };
      const messageMeta = { ...meta(id, labels), threadId: thread, internalDate: date, deletedAt: deleted ? date : null };
      return buildRow(messageMeta, fields, await fakeEmbed(`${subject} ${body}`));
    }),
  );
  await upsertRows(table, rows);
  await ensureIndexes(table, () => {});
}

const run = async (request: Partial<SearchRequest>) => {
  const text = request.text ?? "";
  const hits = await searchTable(
    table,
    { text, vector: text ? await fakeEmbed(text) : null, where: noFilter, sort: "relevance", limit: 10, ...request },
    reranker,
  );
  return hits.map((hit) => hit.id);
};

describe("searchTable", () => {
  it("finds messages by topic", async () => {
    await add([
      { id: "roof", subject: "Roof repair quote", body: "The roofer sent a quote for the repair" },
      { id: "lunch", subject: "Lunch", body: "Pizza on Friday" },
    ]);

    expect((await run({ text: "roof quote" }))[0]).toBe("roof");
  });

  it("applies the filter", async () => {
    await add([
      { id: "acme", from: "billing@acme.com", subject: "Invoice", body: "Invoice attached" },
      { id: "jane", from: "jane@example.com", subject: "Invoice", body: "Invoice attached" },
    ]);
    const where = buildWhere(
      { from: ["acme"], to: [], after: null, before: null, labelIds: [], includeSpamTrash: false, hasAttachment: null },
      TZ,
    );

    expect(await run({ text: "invoice", where })).toEqual(["acme"]);
  });

  it("leaves out deleted messages and spam", async () => {
    await add([
      { id: "kept", subject: "Invoice" },
      { id: "gone", subject: "Invoice", deleted: true },
      { id: "spam", subject: "Invoice", labels: ["SPAM"] },
    ]);

    expect(await run({ text: "invoice" })).toEqual(["kept"]);
  });

  it("returns one message per thread", async () => {
    await add([
      { id: "a1", thread: "a", subject: "Invoice" },
      { id: "a2", thread: "a", subject: "Re: Invoice" },
    ]);

    expect(await run({ text: "invoice" })).toHaveLength(1);
  });

  it("sorts a filter-only search by date", async () => {
    await add([
      { id: "old", date: "2020-01-01T00:00:00.000Z" },
      { id: "new", date: "2024-01-01T00:00:00.000Z" },
      { id: "mid", date: "2022-01-01T00:00:00.000Z" },
    ]);

    expect(await run({ sort: "newest" })).toEqual(["new", "mid", "old"]);
    expect(await run({ sort: "oldest" })).toEqual(["old", "mid", "new"]);
    expect(await run({ sort: "relevance" })).toEqual(["new", "mid", "old"]);
  });

  it("sorts topic matches by date when the query asks for it", async () => {
    await add([
      { id: "old", subject: "Invoice", date: "2020-01-01T00:00:00.000Z" },
      { id: "new", subject: "Invoice", date: "2024-01-01T00:00:00.000Z" },
    ]);

    expect(await run({ text: "invoice", sort: "newest" })).toEqual(["new", "old"]);
  });

  it("returns the display fields", async () => {
    await add([{ id: "a", from: "Jane <jane@example.com>", subject: "Invoice", body: "Total due", labels: ["INBOX"] }]);

    const [hit] = await searchTable(
      table,
      { text: "", vector: null, where: noFilter, sort: "newest", limit: 10 },
      reranker,
    );
    expect(hit).toEqual({
      id: "a",
      threadId: "a",
      date: new Date("2024-03-09T00:00:00.000Z"),
      from: "Jane <jane@example.com>",
      subject: "Invoice",
      snippet: "Total due",
      labels: ["INBOX"],
      hasAttachment: false,
    });
  });
});

describe("newestMessageDate", () => {
  it("returns the date of the newest message that is not deleted", async () => {
    await add([
      { id: "old", date: "2024-03-09T00:00:00.000Z" },
      { id: "new", date: "2024-03-10T12:00:00.000Z" },
      { id: "gone", date: "2024-03-11T00:00:00.000Z", deleted: true },
    ]);

    expect(await newestMessageDate(table)).toEqual(new Date("2024-03-10T12:00:00.000Z"));
  });

  it("returns null for an empty table", async () => {
    expect(await newestMessageDate(table)).toBeNull();
  });
});
