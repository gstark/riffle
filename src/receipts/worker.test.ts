import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import type * as lancedb from "@lancedb/lancedb";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { fakeSource, rawEmail } from "../search/test-fakes.ts";
import type { MessageMeta } from "../shared/storage.ts";
import { meta } from "../sync/test-fakes.ts";
import type { ReceiptModel } from "./extract-receipt.ts";
import { filterRow, RECEIPTS_VERSION } from "./row.ts";
import { openOrCreateReceipts, replaceReceipts } from "./table.ts";
import { extraction, receiptOutput } from "./test-fakes.ts";
import { processBatch, type ReceiptDeps } from "./worker.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "receipts-worker-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const receiptEmail = (subject: string) => rawEmail({ subject, text: "Order Total: $23.45" });
const newsletter = () => rawEmail({ subject: "Weekly digest", text: "Read our latest articles" });
const now = new Date("2026-10-28T12:00:00Z");

/** `raws` maps message IDs to raw messages. Every ID gets a meta. */
async function setup(raws: Record<string, Uint8Array>, metas: MessageMeta[] = Object.keys(raws).map((id) => meta(id))) {
  const { source } = fakeSource({
    metas,
    raws: Object.fromEntries(
      metas.flatMap((m) => {
        const raw = raws[m.id];
        return raw ? [[m.rawKey, raw] as const] : [];
      }),
    ),
  });
  const inputs: string[] = [];
  const model: ReceiptModel = {
    id: "fake-model",
    extract: async (input) => {
      inputs.push(input);
      if (input.includes("FAIL")) throw new Error("model failed");
      if (input.includes("TWO")) return extraction(receiptOutput({ orderId: "1" }), receiptOutput({ orderId: "2" }));
      return extraction(receiptOutput());
    },
  };
  const proofIds: string[][] = [];
  const deps: ReceiptDeps = {
    source,
    table: await openOrCreateReceipts(dir),
    model,
    sendProofs: async (ids) => {
      proofIds.push(ids);
    },
    concurrency: 4,
    now: () => now,
    log: () => {},
  };
  return { deps, inputs, proofIds };
}

async function rowsById(table: lancedb.Table) {
  const rows: Record<string, unknown>[] = await table.query().toArray();
  return new Map(rows.map((row) => [String(row.id), row]));
}

describe("processBatch", () => {
  it("sends messages that pass the filter to the model and records the others as filter rows", async () => {
    const { deps, inputs, proofIds } = await setup({ a: receiptEmail("Your order"), b: newsletter() });

    const result = await processBatch(["a", "b", "a"], deps);

    expect(result).toEqual({ written: 2, removed: 0, modelCalls: 1, failedIds: new Set() });
    expect(proofIds).toEqual([["a"]]);
    expect(inputs).toHaveLength(1);
    expect(inputs[0]).toContain("Subject: Your order");
    const rows = await rowsById(deps.table);
    expect(rows.get("a:0")).toMatchObject({ kind: "order", decidedBy: "fake-model", total: 2345 });
    expect(rows.get("b:0")).toMatchObject({ kind: "none", decidedBy: "filter" });
  });

  it("writes one row for each receipt in a message", async () => {
    const { deps, proofIds } = await setup({ a: receiptEmail("TWO orders") });

    const result = await processBatch(["a"], deps);

    expect(result).toEqual({ written: 2, removed: 0, modelCalls: 1, failedIds: new Set() });
    expect(proofIds).toEqual([["a"]]);
    const rows = await rowsById(deps.table);
    expect([...rows.keys()].toSorted()).toEqual(["a:0", "a:1"]);
    expect(rows.get("a:1")).toMatchObject({ messageId: "a", orderId: "2" });
  });

  it("skips messages that have a row at the current version", async () => {
    const { deps, inputs } = await setup({ a: receiptEmail("Your order") });
    await processBatch(["a"], deps);

    const result = await processBatch(["a"], deps);

    expect(result).toEqual({ written: 0, removed: 0, modelCalls: 0, failedIds: new Set() });
    expect(inputs).toHaveLength(1);
  });

  it("processes messages again when their row has an older version", async () => {
    const { deps } = await setup({ a: receiptEmail("Your order") });
    await replaceReceipts(
      deps.table,
      ["a"],
      [{ ...filterRow(meta("a"), { from: "", subject: "", text: "" }, now), version: 0 }],
    );

    await processBatch(["a"], deps);

    expect((await rowsById(deps.table)).get("a:0")).toMatchObject({ kind: "order", version: RECEIPTS_VERSION });
  });

  it("skips deleted messages and IDs without a meta", async () => {
    const deleted = { ...meta("a"), deletedAt: "2024-04-01T00:00:00.000Z" };
    const { deps } = await setup({ a: receiptEmail("Your order") }, [deleted]);

    const result = await processBatch(["a", "missing"], deps);

    expect(result).toEqual({ written: 0, removed: 0, modelCalls: 0, failedIds: new Set() });
    expect(await deps.table.countRows()).toBe(0);
  });

  it("removes the rows of a message that was deleted after it got rows", async () => {
    const { deps } = await setup({ a: receiptEmail("TWO orders"), b: receiptEmail("Your order") });
    await processBatch(["a", "b"], deps);
    const source = fakeSource({ metas: [{ ...meta("a"), deletedAt: "2024-04-01T00:00:00.000Z" }, meta("b")] }).source;

    const result = await processBatch(["a", "b"], { ...deps, source });

    expect(result).toEqual({ written: 0, removed: 1, modelCalls: 0, failedIds: new Set() });
    expect([...(await rowsById(deps.table)).keys()]).toEqual(["b:0"]);
  });

  it("reports failed messages and still writes the others", async () => {
    const { deps } = await setup({ a: receiptEmail("Your order"), b: receiptEmail("FAIL order") }, [
      meta("a"),
      meta("b"),
      meta("c"),
    ]);

    const result = await processBatch(["a", "b", "c"], deps);

    expect(result).toEqual({ written: 1, removed: 0, modelCalls: 2, failedIds: new Set(["b", "c"]) });
    expect([...(await rowsById(deps.table)).keys()]).toEqual(["a:0"]);
  });
});
