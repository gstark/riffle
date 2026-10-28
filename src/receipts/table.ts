// Access to the LanceDB receipts table. Only the receipts Lambda writes to it.

import * as lancedb from "@lancedb/lancedb";
import { sqlString } from "../search/where.ts";
import { RECEIPTS_TABLE, receiptsSchema, type ReceiptRow } from "./schema.ts";

export async function openOrCreateReceipts(uri: string): Promise<lancedb.Table> {
  const db = await lancedb.connect(uri);
  if ((await db.tableNames()).includes(RECEIPTS_TABLE)) return db.openTable(RECEIPTS_TABLE);
  return db.createEmptyTable(RECEIPTS_TABLE, receiptsSchema);
}

/** The `version` of each ID that has a row. IDs without a row are not in the map. */
export async function readVersions(table: lancedb.Table, ids: string[]): Promise<Map<string, number>> {
  if (ids.length === 0) return new Map();
  const rows: Record<string, unknown>[] = await table
    .query()
    .where(`id IN (${ids.map(sqlString).join(", ")})`)
    .select(["id", "version"])
    .toArray();
  return new Map(rows.map((row) => [String(row.id), Number(row.version)]));
}

/** Adds new rows and replaces existing rows with the same ID, in one table version. */
export async function upsertReceipts(table: lancedb.Table, rows: ReceiptRow[]): Promise<void> {
  if (rows.length === 0) return;
  await table
    .mergeInsert("id")
    .whenMatchedUpdateAll()
    .whenNotMatchedInsertAll()
    .execute(lancedb.makeArrowTable(rows, { schema: receiptsSchema }));
}

export async function deleteReceipts(table: lancedb.Table, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  await table.delete(`id IN (${ids.map(sqlString).join(", ")})`);
}
