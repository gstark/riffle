import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { fakeSource, rawEmail } from "../search/test-fakes.ts";
import { meta } from "../sync/test-fakes.ts";
import { openOrCreateProofs } from "./proof-table.ts";
import { processProofBatch, type ProofsBatchDeps } from "./proofs-worker.ts";
import { filterRow, modelRows } from "./row.ts";
import { openOrCreateReceipts, replaceReceipts } from "./table.ts";
import { extraction, receiptOutput } from "./test-fakes.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "proofs-worker-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const now = new Date("2026-10-28T12:00:00Z");
const email = { from: "Shop <a@shop.example>", subject: "Your order", text: "Total $23.45" };

async function setup() {
  const metas = [meta("a"), meta("b"), meta("c"), { ...meta("d"), deletedAt: now.toISOString() }];
  const { source } = fakeSource({
    metas,
    raws: {
      [metas[0]?.rawKey ?? ""]: rawEmail({ html: '<a href="https://shop.example/receipt/1">View receipt</a>' }),
      [metas[1]?.rawKey ?? ""]: rawEmail({ text: "no receipt here" }),
    },
  });
  const receipts = await openOrCreateReceipts(dir);
  const [a, b, c, d] = metas;
  if (!a || !b || !c || !d) throw new Error("metas");
  await replaceReceipts(
    receipts,
    ["a", "b", "c", "d"],
    [
      ...modelRows(
        a,
        email,
        extraction(receiptOutput({ receiptUrl: null }), receiptOutput({ orderId: "2", receiptUrl: null })),
        "m",
        now,
      ),
      filterRow(b, email, now),
      ...modelRows(c, email, extraction(receiptOutput()), "m", now),
      ...modelRows(d, email, extraction(receiptOutput()), "m", now),
    ],
  );
  const visited: string[] = [];
  const deps: ProofsBatchDeps = {
    source,
    receipts,
    proofs: await openOrCreateProofs(dir),
    browser: {
      visit: async (url) => {
        visited.push(url);
        return {
          ok: true,
          status: 200,
          finalUrl: url,
          pdf: new Uint8Array([1]),
          download: false,
          hasPasswordField: false,
          text: "Total $23.45",
        };
      },
      renderPage: async () => new Uint8Array([2]),
    },
    putPdf: async () => {},
    maxLinks: 3,
    concurrency: 2,
    now: () => now,
    log: () => {},
  };
  return { deps, visited };
}

describe("processProofBatch", () => {
  it("writes a proof row for each receipt and skips messages without receipts", async () => {
    const { deps, visited } = await setup();

    const result = await processProofBatch(["a", "b", "c", "d", "a"], deps);

    // "c" has no raw message in the fake source, so it fails and comes back later.
    expect(result).toEqual({ written: 2, removed: 2, failedIds: new Set(["c"]) });
    expect(visited).toEqual(["https://shop.example/receipt/1"]);
    const rows: Record<string, unknown>[] = await deps.proofs.query().toArray();
    expect(rows.map((row) => [row.id, row.fidelity]).toSorted()).toEqual([
      ["a:0", "merchant_page"],
      ["a:1", "merchant_page"],
    ]);
  });
});
