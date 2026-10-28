// What the receipts model reads and what it returns.

import { z } from "zod";
import type { MessageMeta } from "../shared/storage.ts";
import type { ReceiptEmail } from "./text.ts";

export const KINDS = ["order", "subscription", "refund", "shipping", "none"] as const;
export type Kind = (typeof KINDS)[number];

/** The body text is cut to this many characters before it goes to the model. */
export const MAX_INPUT_CHARS = 12_000;

// zodOutputFormat turns a schema that zod visits twice into a $ref and drops its description. .describe() clones
// the schema and the clone shares its inner type with the original, so the inner type counts twice. Registering the
// description on the instance makes no clone. Each field also needs its own instance, so these are factories.
function described<T extends z.ZodType>(schema: T, description: string): T {
  z.globalRegistry.add(schema, { description });
  return schema;
}
const text = (description: string) => described(z.string().nullable(), description);
const date = (description: string) => described(z.iso.date().nullable(), description);
const amount = () =>
  described(z.number().nullable(), "Decimal amount in currency units, for example 12.99. Positive, also for refunds.");

export const ReceiptSchema = z.object({
  kind: z.enum(KINDS),
  confidence: z.number().describe("0 to 1: how sure you are about kind and the amounts"),
  merchant: text("Merchant name as people say it, for example Amazon or Netflix"),
  orderId: text("Order, invoice, or receipt number"),
  purchaseDate: date("Date of the purchase, charge, or refund that the email body shows"),
  currency: text("ISO 4217 code, for example USD"),
  total: amount(),
  subtotal: amount(),
  tax: amount(),
  shippingCost: amount(),
  discount: amount(),
  paymentMethod: text('Card or account, for example "Visa ending 1234"'),
  items: z.array(
    z.object({
      description: z.string(),
      quantity: z.number().nullable(),
      unitPrice: amount(),
      total: amount(),
    }),
  ),
  receiptUrl: text("The best link to the order, invoice, or receipt page"),
  plan: text("Subscription plan or product name"),
  periodStart: date("Start of the billed subscription period"),
  periodEnd: date("End of the billed subscription period"),
  nextRenewal: date("Date of the next subscription charge"),
  carrier: text("Shipping carrier, for example UPS"),
  trackingNumber: text("Carrier tracking number"),
});
export type ReceiptOutput = z.infer<typeof ReceiptSchema>;

export const SYSTEM_PROMPT = `You read one email and record the purchase in it for a personal finance app. The app matches these records to credit card charges.

Set kind:
- order: confirms a purchase of goods or services, with or without the full price.
- subscription: a receipt for a charge of a recurring plan, such as a monthly renewal. A monthly or yearly invoice from a service is also a subscription.
- refund: money returned to the buyer, including a return confirmation with a refund amount.
- shipping: a shipped, out-for-delivery, or delivered notice for an order, also without amounts.
- none: everything else, including ads, newsletters, abandoned carts, price alerts, price change notices, reminders of future charges, bills that are not paid yet, invoices that the reader sends to others, and money that the reader receives, such as payouts, free trials and other offers with no charge now, and scams. A scam claims to be from a known company but comes from a personal address, such as gmail.com or outlook.com.

Rules:
- Use only values that are in the email. Use null when a value is not there. Do not guess.
- Amounts are decimals in currency units, and they are always positive.
- items lists each product or line with its price. Use an empty list when the email has no lines.
- Links in the email are written as "link text [URL]". For receiptUrl, copy one URL exactly. Prefer links such as order details, view order, receipt, or invoice.
- When kind is none, set every other field to null and items to an empty list.`;

/** The user message for one email. */
export function modelInput(email: ReceiptEmail, meta: MessageMeta): string {
  return [
    `From: ${email.from}`,
    `Subject: ${email.subject}`,
    `Received: ${meta.internalDate}`,
    "",
    email.text.slice(0, MAX_INPUT_CHARS),
  ].join("\n");
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const withNulls = (keys: string[], value: unknown) =>
  isRecord(value) ? { ...Object.fromEntries(keys.map((key) => [key, null])), ...value } : value;
const RECEIPT_KEYS = Object.keys(ReceiptSchema.shape);
const ITEM_KEYS = Object.keys(ReceiptSchema.shape.items.element.shape);

/**
 * Parses the tool input of a model. Models leave out null fields, so a missing field reads as null. A missing
 * confidence reads as 0.
 */
export function parseReceipt(input: unknown): ReceiptOutput {
  const output = withNulls(RECEIPT_KEYS, input);
  if (!isRecord(output)) return ReceiptSchema.parse(output);
  const items = Array.isArray(output.items) ? output.items.map((item) => withNulls(ITEM_KEYS, item)) : [];
  return ReceiptSchema.parse({ ...output, confidence: output.confidence ?? 0, items });
}

/** A model that reads receipts. `id` goes into the decidedBy column. */
export interface ReceiptModel {
  id: string;
  /** Throws when the model gives no valid output. The message then stays in the queue. */
  extract(input: string): Promise<ReceiptOutput>;
}
