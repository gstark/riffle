// LanceDB table of the proof of purchase for each receipt row. Only the proofs Lambda writes to it.
// It is separate from the receipts table, so the receipts Lambda never waits for a browser.

import * as lancedb from "@lancedb/lancedb";
import { Field, Int32, Schema, TimestampMillisecond, Utf8 } from "apache-arrow";
import { sqlString } from "../search/where.ts";
import type { Fidelity } from "./proof.ts";

export const PROOFS_TABLE = "receipt_proofs";

/** Increase after a change to the link rules or the fidelity rules, then run enqueue-proofs.ts again. */
export const PROOFS_VERSION = 1;

const text = (name: string, nullable = true) => new Field(name, new Utf8(), nullable);

export const proofsSchema = new Schema([
  text("id", false),
  text("messageId", false),
  text("fidelity", false),
  text("url"),
  text("finalUrl"),
  new Field("httpStatus", new Int32(), true),
  text("pdfKey"),
  text("emailPdfKey"),
  text("documents", false),
  text("attempts", false),
  new Field("checkedAt", new TimestampMillisecond(), false),
  new Field("version", new Int32(), false),
]);

/** A PDF in the archive bucket. */
export interface ProofDocument {
  key: string;
  source: "attachment" | "link";
  /** File name of an attachment, or the link */
  name: string;
  sha256: string;
  bytes: number;
}

/** One visit to a link. */
export interface ProofAttempt {
  url: string;
  fidelity: Fidelity;
  status: number | null;
  finalUrl: string | null;
  error: string | null;
}

/** One row of the proofs table: the proof of one receipt row. */
export type ProofRow = {
  /** ID of the receipt row */
  id: string;
  messageId: string;
  /** The best proof of this receipt */
  fidelity: Fidelity;
  /** The link of the best link visit, null when no link was opened */
  url: string | null;
  finalUrl: string | null;
  httpStatus: number | null;
  /** Key of the best merchant PDF in the archive bucket: an attachment or a link PDF */
  pdfKey: string | null;
  /** Key of the PDF of the email itself */
  emailPdfKey: string;
  /** JSON list of ProofDocument: all PDFs of the message */
  documents: string;
  /** JSON list of ProofAttempt: all links that were opened, in order */
  attempts: string;
  checkedAt: Date;
  version: number;
};

export async function openOrCreateProofs(uri: string): Promise<lancedb.Table> {
  const db = await lancedb.connect(uri);
  if ((await db.tableNames()).includes(PROOFS_TABLE)) return db.openTable(PROOFS_TABLE);
  return db.createEmptyTable(PROOFS_TABLE, proofsSchema);
}

/** IDs of the messages that have rows at PROOFS_VERSION. */
export async function readCheckedMessages(table: lancedb.Table): Promise<Set<string>> {
  const rows: Record<string, unknown>[] = await table
    .query()
    .where(`version >= ${PROOFS_VERSION}`)
    .select(["messageId"])
    .toArray();
  return new Set(rows.map((row) => String(row.messageId)));
}

/** Replaces all rows of the messages in `messageIds` with `rows`, in one table version. */
export async function replaceProofs(table: lancedb.Table, messageIds: string[], rows: ProofRow[]): Promise<void> {
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
    .execute(lancedb.makeArrowTable(rows, { schema: proofsSchema }));
}
