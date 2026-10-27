// Access to the LanceDB messages table. Only the indexer writes to it.

import * as lancedb from "@lancedb/lancedb";
import { schema, TABLE, toIndexRow, type IndexRow } from "./schema.ts";
import { sqlString } from "./where.ts";

/** IVF-PQ trains on the table's vectors, so it waits until the table has this many rows. */
export const VECTOR_INDEX_MIN_ROWS = 10_000;

/** Keep old table versions for 1 day, so a query that started on an older version can finish. */
const KEEP_VERSIONS_MS = 24 * 60 * 60_000;

export async function openOrCreateTable(uri: string): Promise<lancedb.Table> {
  const db = await lancedb.connect(uri);
  if ((await db.tableNames()).includes(TABLE)) return db.openTable(TABLE);
  return db.createEmptyTable(TABLE, schema);
}

/** Reads the rows with these IDs, by ID. IDs without a row are not in the map. */
export async function readRows(table: lancedb.Table, ids: string[]): Promise<Map<string, IndexRow>> {
  if (ids.length === 0) return new Map();
  const rows: Record<string, unknown>[] = await table
    .query()
    .where(`id IN (${ids.map(sqlString).join(", ")})`)
    .toArray();
  return new Map(rows.map((raw) => [String(raw.id), toIndexRow(raw)]));
}

/** Adds new rows and replaces existing rows with the same ID, in one table version. */
export async function upsertRows(table: lancedb.Table, rows: IndexRow[]): Promise<void> {
  if (rows.length === 0) return;
  await table
    .mergeInsert("id")
    .whenMatchedUpdateAll()
    .whenNotMatchedInsertAll()
    .execute(lancedb.makeArrowTable(rows, { schema }));
}

/**
 * The full-text index, with token positions for quoted phrases. The first text index, `text_idx`, had no positions:
 * the JS binding leaves `withPosition` unset and Lance then builds without them. The new name lets
 * ensureIndexes tell the two apart and replace the old one.
 */
export const TEXT_INDEX = "text_phrase_idx";
const OLD_TEXT_INDEX = "text_idx";

/** Creates each index that does not exist yet, and replaces the text index that has no positions. */
export async function ensureIndexes(table: lancedb.Table, log: (message: string) => void): Promise<void> {
  const rowCount = await table.countRows();
  if (rowCount === 0) return;

  const wanted: [string, lancedb.Index, string?][] = [
    ["id", lancedb.Index.btree()],
    ["date", lancedb.Index.btree()],
    ["labels", lancedb.Index.labelList()],
    ["fromKey", lancedb.Index.fm()],
    ["toKey", lancedb.Index.fm()],
    ["text", lancedb.Index.fts({ withPosition: true, stem: true, removeStopWords: true }), TEXT_INDEX],
  ];
  if (rowCount >= VECTOR_INDEX_MIN_ROWS) wanted.push(["vector", lancedb.Index.ivfPq({ distanceType: "cosine" })]);

  const existing = new Set((await table.listIndices()).map((index) => index.name));
  for (const [column, config, name = `${column}_idx`] of wanted) {
    if (existing.has(name)) continue;
    log(`Creating the ${name} index`);
    await table.createIndex(column, { config, name });
  }
  // The new text index is in place, so searches keep working while the old one goes.
  if (existing.has(OLD_TEXT_INDEX)) {
    log(`Dropping the ${OLD_TEXT_INDEX} index, which has no positions`);
    await table.dropIndex(OLD_TEXT_INDEX);
  }
}

/** Merges small files, adds new rows to the indexes, and deletes old versions. */
export async function optimize(table: lancedb.Table): Promise<void> {
  await table.optimize({ cleanupOlderThan: new Date(Date.now() - KEEP_VERSIONS_MS) });
}
