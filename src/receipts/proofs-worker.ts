// Turns a batch of message IDs from the proofs queue into rows of the receipt_proofs table.

import type * as lancedb from "@lancedb/lancedb";
import type { MessageSource } from "../search/source.ts";
import { sqlString } from "../search/where.ts";
import { runPool } from "../sync/pool.ts";
import { checkMessage, type ProofDeps, type ProofReceipt } from "./proof-pass.ts";
import { readProofEmail } from "./proof-email.ts";
import { replaceProofs, type ProofRow } from "./proof-table.ts";

/** IDs in each proofs queue message and in each batch. One email can take about 2 minutes when all its links time out. */
export const PROOFS_BATCH_IDS = 8;

export interface ProofsBatchDeps extends ProofDeps {
  source: MessageSource;
  /** The receipts table. The worker only reads it. */
  receipts: lancedb.Table;
  proofs: lancedb.Table;
  /** Messages checked at the same time */
  concurrency: number;
  log: (message: string) => void;
}

export interface ProofsBatchResult {
  written: number;
  /** Messages without receipts, or deleted, whose proof rows were removed */
  removed: number;
  /** IDs to try again later */
  failedIds: Set<string>;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));
const nullable = (value: unknown) => (value === null || value === undefined ? null : String(value));

/** The receipts (not the "none" rows) of each message. */
export async function readProofReceipts(
  table: lancedb.Table,
  messageIds: string[],
): Promise<Map<string, ProofReceipt[]>> {
  const byMessage = new Map<string, ProofReceipt[]>();
  if (messageIds.length === 0) return byMessage;
  const rows: Record<string, unknown>[] = await table
    .query()
    .where(`kind != 'none' AND messageId IN (${messageIds.map(sqlString).join(", ")})`)
    .select(["id", "messageId", "total", "currency", "orderId", "receiptUrl"])
    .toArray();
  for (const row of rows) {
    const receipt: ProofReceipt = {
      id: String(row.id),
      messageId: String(row.messageId),
      total: row.total === null ? null : Number(row.total),
      currency: nullable(row.currency),
      orderId: nullable(row.orderId),
      receiptUrl: nullable(row.receiptUrl),
    };
    byMessage.set(receipt.messageId, [...(byMessage.get(receipt.messageId) ?? []), receipt]);
  }
  return byMessage;
}

/** Replaces the proof rows of each message in one table write. A message that fails keeps its old rows. */
export async function processProofBatch(ids: string[], deps: ProofsBatchDeps): Promise<ProofsBatchResult> {
  const unique = [...new Set(ids)];
  const receipts = await readProofReceipts(deps.receipts, unique);
  const rows: ProofRow[] = [];
  const doneIds: string[] = [];
  const result: ProofsBatchResult = { written: 0, removed: 0, failedIds: new Set() };

  await runPool(unique, deps.concurrency, async (id) => {
    try {
      const meta = await deps.source.getMeta(id);
      const own = receipts.get(id) ?? [];
      if (!meta || meta.deletedAt !== null || own.length === 0) {
        result.removed++;
      } else {
        const email = await readProofEmail(await deps.source.getRaw(meta.rawKey));
        const checked = await checkMessage(id, email, own, deps);
        rows.push(...checked);
        deps.log(`${id}: ${checked.map((row) => row.fidelity).join(", ")}`);
      }
      doneIds.push(id);
    } catch (error) {
      result.failedIds.add(id);
      deps.log(`Failed ${id}: ${errorText(error)}`);
    }
  });

  await replaceProofs(deps.proofs, doneIds, rows);
  result.written = rows.length;
  return result;
}
