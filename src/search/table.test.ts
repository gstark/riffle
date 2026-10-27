import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { buildRow } from "./row.ts";
import * as lancedb from "@lancedb/lancedb";
import { ensureIndexes, openOrCreateTable, readRows, TEXT_INDEX, upsertRows } from "./table.ts";
import { unitVector } from "./test-fakes.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "search-table-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const row = (id: string, labels = ["INBOX"]) =>
  buildRow(
    meta(id, labels),
    { from: "a@example.com", to: "b@example.com", subject: `Subject ${id}`, attachments: [], body: `Body ${id}` },
    unitVector(),
  );

describe("table", () => {
  it("creates the table, then adds and replaces rows by id", async () => {
    const table = await openOrCreateTable(dir);
    await upsertRows(table, [row("a"), row("b")]);
    await upsertRows(table, [row("a", ["STARRED"])]);

    expect(await table.countRows()).toBe(2);
    const rows = await readRows(table, ["a", "missing"]);
    expect([...rows.keys()]).toEqual(["a"]);
    expect(rows.get("a")).toEqual(row("a", ["STARRED"]));
  });

  it("opens the existing table", async () => {
    await upsertRows(await openOrCreateTable(dir), [row("a")]);

    expect(await (await openOrCreateTable(dir)).countRows()).toBe(1);
  });

  it("creates the scalar and full-text indexes, and waits for more rows before the vector index", async () => {
    const table = await openOrCreateTable(dir);
    await upsertRows(table, [row("a")]);
    await ensureIndexes(table, () => {});

    const indexes = (await table.listIndices()).map((index) => `${index.columns.join()}:${index.name}`).toSorted();
    expect(indexes).toEqual(["date:date_idx", "fromKey:fromKey_idx", "id:id_idx", "labels:labels_idx", `text:${TEXT_INDEX}`, "toKey:toKey_idx"]);
  });

  it("replaces the text index that has no positions", async () => {
    const table = await openOrCreateTable(dir);
    await upsertRows(table, [row("a")]);
    await table.createIndex("text", { config: lancedb.Index.fts({ stem: true, removeStopWords: true }) });
    const phrase = () =>
      table.query().fullTextSearch(new lancedb.PhraseQuery("subject a", "text")).select(["id"]).toArray();
    await expect(phrase()).rejects.toThrow(/position/);

    await ensureIndexes(table, () => {});

    const names = (await table.listIndices()).filter((index) => index.columns.includes("text")).map((index) => index.name);
    expect(names).toEqual([TEXT_INDEX]);
    expect((await phrase()).map((r) => r.id)).toEqual(["a"]);
  });

  it("does not create indexes on an empty table", async () => {
    const table = await openOrCreateTable(dir);
    await ensureIndexes(table, () => {});

    expect(await table.listIndices()).toEqual([]);
  });
});
