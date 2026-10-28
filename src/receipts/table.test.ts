import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { filterRow, modelRows, RECEIPTS_VERSION } from "./row.ts";
import { openOrCreateReceipts, readVersions, replaceReceipts } from "./table.ts";
import { extraction, receiptOutput } from "./test-fakes.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "receipts-table-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const email = { from: "x", subject: "y", text: "z" };
const now = new Date("2026-10-28T12:00:00Z");

const orders = (id: string, count: number) =>
  modelRows(meta(id), email, extraction(...Array.from({ length: count }, () => receiptOutput())), "m", now);
const ids = async (table: Awaited<ReturnType<typeof openOrCreateReceipts>>) =>
  (await table.query().select(["id"]).toArray()).map((row: Record<string, unknown>) => String(row.id)).toSorted();

describe("receipts table", () => {
  it("writes rows with null fields and reads the version of each message", async () => {
    const table = await openOrCreateReceipts(dir);

    await replaceReceipts(table, ["a", "b"], [
      filterRow(meta("a"), email, now),
      ...orders("b", 2).map((row) => ({ ...row, version: 7 })),
    ]);

    expect(await readVersions(table, ["a", "b", "c"])).toEqual(new Map([["a", RECEIPTS_VERSION], ["b", 7]]));
    const rows = await table.query().where("id = 'b:1'").toArray();
    expect(rows[0]).toMatchObject({ messageId: "b", kind: "order", total: 2345, discount: null, currency: "USD" });
  });

  it("replaces all rows of a message, and keeps the rows of other messages", async () => {
    const table = await openOrCreateReceipts(dir);
    await replaceReceipts(table, ["a", "b"], [...orders("a", 3), filterRow(meta("b"), email, now)]);

    await replaceReceipts(table, ["a"], orders("a", 2));

    expect(await ids(table)).toEqual(["a:0", "a:1", "b:0"]);
  });

  it("removes the rows of a message without new rows", async () => {
    const table = await openOrCreateReceipts(dir);
    await replaceReceipts(table, ["a", "b"], [...orders("a", 2), filterRow(meta("b"), email, now)]);

    await replaceReceipts(table, ["a"], []);
    expect(await ids(table)).toEqual(["b:0"]);

    await replaceReceipts(table, ["b", "c"], orders("c", 1));
    expect(await ids(table)).toEqual(["c:0"]);
  });

  it("opens the table that exists", async () => {
    await replaceReceipts(await openOrCreateReceipts(dir), ["a"], [filterRow(meta("a"), email, now)]);

    expect(await (await openOrCreateReceipts(dir)).countRows()).toBe(1);
  });
});
