// LanceDB table of the proofs that the Riffle app made with a sign-in. Only the search Lambda writes to it.
// It is separate from `receipt_proofs`, so a new run of the proofs Lambda cannot overwrite these proofs.

import * as lancedb from "@lancedb/lancedb";
import { Field, Int32, Schema, TimestampMillisecond, Utf8 } from "apache-arrow";
import { sqlString } from "../search/where.ts";
import { PROOFS_TABLE } from "./proof-table.ts";
import { RECEIPTS_TABLE } from "./schema.ts";
import { PENDING_FIDELITIES, type Candidate, type SignedInRow } from "./signed-in.ts";

export const SIGNED_IN_TABLE = "signed_in_proofs";
/** The table gets one small fragment for each row. Compact it after this many rows. */
const OPTIMIZE_EVERY = 50;

const text = (name: string, nullable = true) => new Field(name, new Utf8(), nullable);

export const signedInSchema = new Schema([
  text("id", false),
  text("messageId", false),
  text("site", false),
  text("fidelity", false),
  text("url", false),
  text("finalUrl", false),
  new Field("httpStatus", new Int32(), true),
  text("pdfKey", false),
  new Field("checkedAt", new TimestampMillisecond(), false),
]);

export async function openOrCreateSignedIn(db: lancedb.Connection): Promise<lancedb.Table> {
  if ((await db.tableNames()).includes(SIGNED_IN_TABLE)) return db.openTable(SIGNED_IN_TABLE);
  return db.createEmptyTable(SIGNED_IN_TABLE, signedInSchema);
}

/** Adds or replaces the row of one receipt. */
export async function writeSignedIn(table: lancedb.Table, row: SignedInRow): Promise<void> {
  await table
    .mergeInsert("id")
    .whenMatchedUpdateAll()
    .whenNotMatchedInsertAll()
    .execute(lancedb.makeArrowTable([row], { schema: signedInSchema }));
  if ((await table.countRows()) % OPTIMIZE_EVERY === 0) await table.optimize();
}

export interface CandidateTables {
  proofs: lancedb.Table;
  receipts: lancedb.Table;
  signedIn: lancedb.Table;
}

/** Opens the tables of the candidate query. The proofs and receipts tables must exist. */
export async function openCandidateTables(db: lancedb.Connection): Promise<CandidateTables> {
  return {
    proofs: await db.openTable(PROOFS_TABLE),
    receipts: await db.openTable(RECEIPTS_TABLE),
    signedIn: await openOrCreateSignedIn(db),
  };
}

type Row = Record<string, unknown>;
const textOrNull = (value: unknown) => (value === null || value === undefined ? null : String(value));
const numberOrNull = (value: unknown) => (value === null || value === undefined ? null : Number(value));

/**
 * Receipts with a `login_required` or `blocked` proof. With `id`, only that receipt, also when it has a signed-in
 * row. Without `id`, all receipts without a signed-in row.
 */
export async function readCandidates(tables: CandidateTables, id?: string): Promise<Candidate[]> {
  const pending = `fidelity IN (${PENDING_FIDELITIES.map(sqlString).join(", ")})`;
  const proofRows: Row[] = await tables.proofs
    .query()
    .where(id === undefined ? pending : `${pending} AND id = ${sqlString(id)}`)
    .select(["id", "url", "finalUrl"])
    .toArray();

  const done =
    id === undefined
      ? new Set((await tables.signedIn.query().select(["id"]).toArray()).map((row: Row) => String(row.id)))
      : new Set<string>();
  const proofs = new Map(proofRows.filter((row) => !done.has(String(row.id))).map((row) => [String(row.id), row]));
  if (proofs.size === 0) return [];

  const receiptRows: Row[] = await tables.receipts
    .query()
    .where(`id IN (${[...proofs.keys()].map(sqlString).join(", ")})`)
    .select(["id", "messageId", "date", "subject", "merchant", "orderId", "total", "currency"])
    .toArray();

  return receiptRows.map((row) => {
    const proof = proofs.get(String(row.id));
    return {
      id: String(row.id),
      messageId: String(row.messageId),
      date: new Date(Number(row.date)),
      subject: String(row.subject),
      merchant: textOrNull(row.merchant),
      orderId: textOrNull(row.orderId),
      total: numberOrNull(row.total),
      currency: textOrNull(row.currency),
      url: textOrNull(proof?.url),
      finalUrl: textOrNull(proof?.finalUrl),
    };
  });
}
