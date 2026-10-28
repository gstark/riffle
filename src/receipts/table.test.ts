import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { filterRow, modelRow, RECEIPTS_VERSION } from "./row.ts";
import { openOrCreateReceipts, readVersions, upsertReceipts } from "./table.ts";
import { receiptOutput } from "./test-fakes.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "receipts-table-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const email = { from: "x", subject: "y", text: "z" };
const now = new Date("2026-10-28T12:00:00Z");

describe("receipts table", () => {
  it("writes rows with null fields and reads their versions", async () => {
    const table = await openOrCreateReceipts(dir);

    await upsertReceipts(table, [
      filterRow(meta("a"), email, now),
      { ...modelRow(meta("b"), email, receiptOutput(), "m", now), version: 7 },
    ]);

    expect(await readVersions(table, ["a", "b", "c"])).toEqual(new Map([["a", RECEIPTS_VERSION], ["b", 7]]));
    const rows = await table.query().where("id = 'b'").toArray();
    expect(rows[0]).toMatchObject({ kind: "order", total: 2345, discount: null, currency: "USD" });
  });

  it("replaces a row with the same ID", async () => {
    const table = await openOrCreateReceipts(dir);
    await upsertReceipts(table, [filterRow(meta("a"), email, now)]);

    await upsertReceipts(table, [modelRow(meta("a"), email, receiptOutput(), "m", now)]);

    expect(await table.countRows()).toBe(1);
    expect((await table.query().toArray())[0]).toMatchObject({ kind: "order" });
  });

  it("opens the table that exists", async () => {
    await upsertReceipts(await openOrCreateReceipts(dir), [filterRow(meta("a"), email, now)]);

    expect(await (await openOrCreateReceipts(dir)).countRows()).toBe(1);
  });
});
