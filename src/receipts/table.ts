// Access to the LanceDB receipts table. Only the receipts Lambda writes to it.

import * as lancedb from "@lancedb/lancedb";
import { sqlString } from "../search/where.ts";
import { RECEIPTS_TABLE, receiptsSchema, type ReceiptRow } from "./schema.ts";

export async function openOrCreateReceipts(uri: string): Promise<lancedb.Table> {
  const db = await lancedb.connect(uri);
  if ((await db.tableNames()).includes(RECEIPTS_TABLE)) return db.openTable(RECEIPTS_TABLE);
  return db.createEmptyTable(RECEIPTS_TABLE, receiptsSchema);
}

/** The `version` of each message that has rows. Messages without rows are not in the map. */
export async function readVersions(table: lancedb.Table, messageIds: string[]): Promise<Map<string, number>> {
  if (messageIds.length === 0) return new Map();
  const rows: Record<string, unknown>[] = await table
    .query()
    .where(`messageId IN (${messageIds.map(sqlString).join(", ")})`)
    .select(["messageId", "version"])
    .toArray();
  return new Map(rows.map((row) => [String(row.messageId), Number(row.version)]));
}

/**
 * Replaces all rows of the messages in `messageIds` with `rows`, in one table version. A message without new rows
 * loses its old rows.
 */
export async function replaceReceipts(table: lancedb.Table, messageIds: string[], rows: ReceiptRow[]): Promise<void> {
  if (messageIds.length === 0) return;
  const where = `messageId IN (${messageIds.map(sqlString).join(", ")})`;
  if (rows.length === 0) {
    await table.delete(where);
    return;
  }
  await table
    .mergeInsert("id")
    .whenMatchedUpdateAll()
    .whenNotMatchedInsertAll()
    .whenNotMatchedBySourceDelete({ where })
    .execute(lancedb.makeArrowTable(rows, { schema: receiptsSchema }));
}
