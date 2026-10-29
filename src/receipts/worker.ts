// Turns a batch of message IDs from the receipts queue into rows of the receipts table.

import type * as lancedb from "@lancedb/lancedb";
import type { MessageSource } from "../search/source.ts";
import { runPool } from "../sync/pool.ts";
import { modelInput, type ReceiptModel } from "./extract-receipt.ts";
import { passesFilter } from "./filter.ts";
import { filterRow, modelRows, RECEIPTS_VERSION } from "./row.ts";
import type { ReceiptRow } from "./schema.ts";
import { readVersions, replaceReceipts } from "./table.ts";
import { readReceiptEmail } from "./text.ts";

export interface ReceiptDeps {
  source: MessageSource;
  table: lancedb.Table;
  model: ReceiptModel;
  /** Sends the IDs of messages with new receipts to the proofs queue. */
  sendProofs: (messageIds: string[]) => Promise<void>;
  /** Model calls at the same time */
  concurrency: number;
  now: () => Date;
  log: (message: string) => void;
}

export interface ReceiptBatchResult {
  /** Rows written. A message can have more than one row. */
  written: number;
  /** Deleted messages whose rows were removed */
  removed: number;
  /** Messages that went to the model, also the ones that failed */
  modelCalls: number;
  /** IDs to try again later */
  failedIds: Set<string>;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

/**
 * Writes the rows of each message that has no rows at RECEIPTS_VERSION, in one table write. The new rows replace the
 * old rows of the message. Deleted messages get no rows, and their old rows are removed. A message that fails stays out of the table and is in
 * `failedIds`. Messages with new receipts go to the proofs queue.
 */
export async function processBatch(ids: string[], deps: ReceiptDeps): Promise<ReceiptBatchResult> {
  const unique = [...new Set(ids)];
  const versions = await readVersions(deps.table, unique);
  const rows: ReceiptRow[] = [];
  const writtenIds: string[] = [];
  const removedIds: string[] = [];
  const result: ReceiptBatchResult = { written: 0, removed: 0, modelCalls: 0, failedIds: new Set() };

  await runPool(unique, deps.concurrency, async (id) => {
    const version = versions.get(id);
    try {
      const meta = await deps.source.getMeta(id);
      if (!meta || meta.deletedAt !== null) {
        if (version !== undefined) removedIds.push(id);
        return;
      }
      if ((version ?? 0) >= RECEIPTS_VERSION) return;
      const email = await readReceiptEmail(await deps.source.getRaw(meta.rawKey));
      if (!passesFilter(email.subject, email.text)) {
        rows.push(filterRow(meta, email, deps.now()));
      } else {
        result.modelCalls++;
        const output = await deps.model.extract(modelInput(email, meta));
        rows.push(...modelRows(meta, email, output, deps.model.id, deps.now()));
      }
      writtenIds.push(id);
    } catch (error) {
      result.failedIds.add(id);
      deps.log(`Failed ${id}: ${errorText(error)}`);
    }
  });

  await replaceReceipts(deps.table, [...writtenIds, ...removedIds], rows);
  // A failed send does not undo the write. enqueue-proofs.ts finds receipts without proofs.
  await deps.sendProofs([...new Set(rows.filter((row) => row.kind !== "none").map((row) => row.messageId))]);
  result.written = rows.length;
  result.removed = removedIds.length;
  return result;
}
