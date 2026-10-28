// LanceDB table of processed messages and the purchase data in them. Only the receipts Lambda writes it.
// It is in the same LanceDB store as the messages table (the index bucket).

import { Field, Float64, Int32, Schema, TimestampMillisecond, Utf8 } from "apache-arrow";
import type { Kind } from "./extract-receipt.ts";

export const RECEIPTS_TABLE = "receipts";

const text = (name: string, nullable = true) => new Field(name, new Utf8(), nullable);
const minorUnits = (name: string) => new Field(name, new Int32(), true);

export const receiptsSchema = new Schema([
  text("id", false),
  text("threadId", false),
  new Field("date", new TimestampMillisecond(), false),
  text("from", false),
  text("subject", false),
  text("kind", false),
  text("decidedBy", false),
  new Field("version", new Int32(), false),
  new Field("confidence", new Float64(), false),
  new Field("extractedAt", new TimestampMillisecond(), false),
  text("merchant"),
  text("orderId"),
  text("purchaseDate"),
  text("currency"),
  minorUnits("total"),
  minorUnits("subtotal"),
  minorUnits("tax"),
  minorUnits("shippingCost"),
  minorUnits("discount"),
  text("paymentMethod"),
  text("items", false),
  text("receiptUrl"),
  text("plan"),
  text("periodStart"),
  text("periodEnd"),
  text("nextRenewal"),
  text("carrier"),
  text("trackingNumber"),
]);

/** One row of the receipts table. Amounts are in minor units of `currency`. Dates without a time are "YYYY-MM-DD". */
export type ReceiptRow = {
  id: string;
  threadId: string;
  /** Gmail receive time */
  date: Date;
  from: string;
  subject: string;
  kind: Kind;
  /** "filter", or the Bedrock model ID */
  decidedBy: string;
  /** RECEIPTS_VERSION when the row was made */
  version: number;
  confidence: number;
  extractedAt: Date;
  merchant: string | null;
  orderId: string | null;
  purchaseDate: string | null;
  currency: string | null;
  total: number | null;
  subtotal: number | null;
  tax: number | null;
  shippingCost: number | null;
  discount: number | null;
  paymentMethod: string | null;
  /** JSON list of {description, quantity, unitPrice, total}. Prices are in minor units. */
  items: string;
  receiptUrl: string | null;
  plan: string | null;
  periodStart: string | null;
  periodEnd: string | null;
  nextRenewal: string | null;
  carrier: string | null;
  trackingNumber: string | null;
};
