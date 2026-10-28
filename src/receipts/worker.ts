// Turns a batch of message IDs from the receipts queue into rows of the receipts table.

import type * as lancedb from "@lancedb/lancedb";
import type { MessageSource } from "../search/source.ts";
import { runPool } from "../sync/pool.ts";
import { modelInput, type ReceiptModel } from "./extract-receipt.ts";
import { passesFilter } from "./filter.ts";
import { filterRow, modelRow, RECEIPTS_VERSION } from "./row.ts";
import type { ReceiptRow } from "./schema.ts";
import { deleteReceipts, readVersions, upsertReceipts } from "./table.ts";
import { readReceiptEmail } from "./text.ts";

export interface ReceiptDeps {
  source: MessageSource;
  table: lancedb.Table;
  model: ReceiptModel;
  /** Model calls at the same time */
  concurrency: number;
  now: () => Date;
  log: (message: string) => void;
}

export interface ReceiptBatchResult {
  written: number;
  /** Rows of deleted messages that were removed */
  removed: number;
  /** Messages that went to the model, also the ones that failed */
  modelCalls: number;
  /** IDs to try again later */
  failedIds: Set<string>;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

/**
 * Writes a row for each ID that has no row at RECEIPTS_VERSION, in one table write.
 * Deleted messages get no row, and their old row is removed. A message that fails stays out of the table and is in
 * `failedIds`.
 */
export async function processBatch(ids: string[], deps: ReceiptDeps): Promise<ReceiptBatchResult> {
  const unique = [...new Set(ids)];
  const versions = await readVersions(deps.table, unique);
  const rows: ReceiptRow[] = [];
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
        return;
      }
      result.modelCalls++;
      const output = await deps.model.extract(modelInput(email, meta));
      rows.push(modelRow(meta, email, output, deps.model.id, deps.now()));
    } catch (error) {
      result.failedIds.add(id);
      deps.log(`Failed ${id}: ${errorText(error)}`);
    }
  });

  await upsertReceipts(deps.table, rows);
  await deleteReceipts(deps.table, removedIds);
  result.written = rows.length;
  result.removed = removedIds.length;
  return result;
}
