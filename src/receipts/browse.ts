// The receipts for the Receipts window of the Riffle app: all receipts with their best PDF. The search Lambda
// serves them at GET /receipts. The app loads all of them and filters them on the Mac.

import * as lancedb from "@lancedb/lancedb";
import { BadRequestError } from "../search/request.ts";
import { gmailUrl } from "../search/service.ts";
import { sqlString } from "../search/where.ts";
import type { Kind } from "./extract-receipt.ts";
import { PROVES, type Fidelity } from "./proof.ts";
import type { CandidateTables } from "./signed-in-table.ts";

/** "merchant": a PDF from the merchant, for example an invoice. "email": only the PDF of the email. */
export type ProofKind = "merchant" | "email";

export interface BrowseItem {
  description: string;
  quantity: number | null;
  /** Minor units */
  unitPrice: number | null;
  total: number | null;
}

export interface BrowseReceipt {
  id: string;
  gmailUrl: string;
  /** Gmail receive time, ISO 8601 */
  date: string;
  kind: Exclude<Kind, "none">;
  subject: string;
  merchant: string | null;
  orderId: string | null;
  /** "YYYY-MM-DD" */
  purchaseDate: string | null;
  currency: string | null;
  /** Minor units of `currency`, always positive. A refund has kind "refund". */
  total: number | null;
  subtotal: number | null;
  tax: number | null;
  shippingCost: number | null;
  discount: number | null;
  paymentMethod: string | null;
  items: BrowseItem[];
  plan: string | null;
  periodStart: string | null;
  periodEnd: string | null;
  /** The best PDF of the receipt, null when it has none */
  proof: ProofKind | null;
  /** True when the archive has a PDF of the email, for the Email tab of the Receipts window */
  hasEmailPdf: boolean;
}

type Row = Record<string, unknown>;

/** "best": the best PDF of the receipt. "email": the PDF of the email. */
export type PdfChoice = "best" | "email";

const RECEIPT_FIELDS = [
  "id", "threadId", "date", "kind", "subject", "merchant", "orderId", "purchaseDate", "currency", "total", "subtotal",
  "tax", "shippingCost", "discount", "paymentMethod", "items", "plan", "periodStart", "periodEnd",
];

const textOrNull = (value: unknown) => (value === null || value === undefined ? null : String(value));
const numberOrNull = (value: unknown) => (value === null || value === undefined ? null : Number(value));

/**
 * The key of the best PDF of a receipt, and its kind: a signed-in PDF, then a merchant PDF that proves the receipt,
 * then the PDF of the email.
 */
export function bestPdf(proof: Row | undefined, signedIn: Row | undefined): { key: string; kind: ProofKind } | null {
  const signedInKey = textOrNull(signedIn?.pdfKey);
  if (signedInKey) return { key: signedInKey, kind: "merchant" };
  const merchantKey = textOrNull(proof?.pdfKey);
  if (merchantKey && PROVES.has(proof?.fidelity as Fidelity)) return { key: merchantKey, kind: "merchant" };
  const emailKey = textOrNull(proof?.emailPdfKey);
  return emailKey ? { key: emailKey, kind: "email" } : null;
}

/** Joins receipt rows with their proof rows. Newest first. */
export function toBrowseReceipts(receipts: Row[], proofs: Row[], signedIn: Row[], gmailUser: string): BrowseReceipt[] {
  const proofById = new Map(proofs.map((row) => [String(row.id), row]));
  const signedInById = new Map(signedIn.map((row) => [String(row.id), row]));
  return receipts
    .toSorted((a, b) => Number(b.date) - Number(a.date))
    .map((row) => {
      const id = String(row.id);
      return {
        id,
        gmailUrl: gmailUrl(gmailUser, String(row.threadId)),
        date: new Date(Number(row.date)).toISOString(),
        kind: row.kind as BrowseReceipt["kind"],
        subject: String(row.subject),
        merchant: textOrNull(row.merchant),
        orderId: textOrNull(row.orderId),
        purchaseDate: textOrNull(row.purchaseDate),
        currency: textOrNull(row.currency),
        total: numberOrNull(row.total),
        subtotal: numberOrNull(row.subtotal),
        tax: numberOrNull(row.tax),
        shippingCost: numberOrNull(row.shippingCost),
        discount: numberOrNull(row.discount),
        paymentMethod: textOrNull(row.paymentMethod),
        items: JSON.parse(String(row.items)) as BrowseItem[],
        plan: textOrNull(row.plan),
        periodStart: textOrNull(row.periodStart),
        periodEnd: textOrNull(row.periodEnd),
        proof: bestPdf(proofById.get(id), signedInById.get(id))?.kind ?? null,
        hasEmailPdf: textOrNull(proofById.get(id)?.emailPdfKey) !== null,
      };
    });
}

export interface ReceiptsDeps {
  tables: () => Promise<CandidateTables>;
  gmailUser: string;
  /** A link that downloads the object of the archive bucket for a short time. */
  presign: (key: string) => Promise<string>;
}

export function createReceipts(deps: ReceiptsDeps) {
  return {
    list: async (): Promise<BrowseReceipt[]> => {
      const tables = await deps.tables();
      const [receipts, proofs, signedIn] = await Promise.all([
        tables.receipts.query().where("kind != 'none'").select(RECEIPT_FIELDS).toArray() as Promise<Row[]>,
        tables.proofs.query().select(["id", "fidelity", "pdfKey", "emailPdfKey"]).toArray() as Promise<Row[]>,
        tables.signedIn.query().where("pdfKey IS NOT NULL").select(["id", "pdfKey"]).toArray() as Promise<Row[]>,
      ]);
      return toBrowseReceipts(receipts, proofs, signedIn, deps.gmailUser);
    },

    /** A download link for the best PDF of the receipt, or for the PDF of its email. */
    pdfUrl: async (id: string, which: PdfChoice = "best"): Promise<string> => {
      const tables = await deps.tables();
      const where = `id = ${sqlString(id)}`;
      const first = async (table: lancedb.Table, columns: string[]) =>
        ((await table.query().where(where).select(columns).limit(1).toArray()) as Row[])[0];
      const proof = await first(tables.proofs, ["fidelity", "pdfKey", "emailPdfKey"]);
      const key =
        which === "email" ? textOrNull(proof?.emailPdfKey) : bestPdf(proof, await first(tables.signedIn, ["pdfKey"]))?.key;
      if (!key) throw new BadRequestError(`Receipt ${id} has no ${which === "email" ? "email " : ""}PDF`);
      return deps.presign(key);
    },
  };
}

export type Receipts = ReturnType<typeof createReceipts>;
