// Builds receipts table rows.

import type { MessageMeta } from "../shared/storage.ts";
import type { ExtractionOutput, ReceiptOutput } from "./extract-receipt.ts";
import type { ReceiptRow } from "./schema.ts";
import type { ReceiptEmail } from "./text.ts";

/**
 * Version of the filter rules and the prompt. Increase it after a change to either:
 * the worker then processes the messages with older rows again.
 */
export const RECEIPTS_VERSION = 3;

/** Digits after the decimal point: 2 for USD, 0 for JPY, 3 for KWD. 2 when the code is missing or not valid. */
export function currencyDigits(currency: string | null): number {
  if (!currency) return 2;
  try {
    return new Intl.NumberFormat("en", { style: "currency", currency }).resolvedOptions().maximumFractionDigits ?? 2;
  } catch {
    return 2;
  }
}

const INT32_MAX = 2_147_483_647;

/** A decimal amount in minor units of the currency, always positive. Null when it does not fit the Int32 column. */
export function toMinor(amount: number | null, currency: string | null): number | null {
  if (amount === null) return null;
  const minor = Math.round(Math.abs(amount) * 10 ** currencyDigits(currency));
  return minor > INT32_MAX ? null : minor;
}

const EMPTY_FIELDS = {
  merchant: null,
  orderId: null,
  purchaseDate: null,
  currency: null,
  total: null,
  subtotal: null,
  tax: null,
  shippingCost: null,
  discount: null,
  paymentMethod: null,
  items: "[]",
  receiptUrl: null,
  plan: null,
  periodStart: null,
  periodEnd: null,
  nextRenewal: null,
  carrier: null,
  trackingNumber: null,
} as const;

function messageFields(meta: MessageMeta, email: ReceiptEmail, n: number, now: Date) {
  return {
    id: `${meta.id}:${n}`,
    messageId: meta.id,
    threadId: meta.threadId,
    date: new Date(meta.internalDate),
    from: email.from,
    subject: email.subject,
    version: RECEIPTS_VERSION,
    extractedAt: now,
  };
}

/** The row of a message without receipts. */
function noneRow(meta: MessageMeta, email: ReceiptEmail, decidedBy: string, now: Date): ReceiptRow {
  return { ...messageFields(meta, email, 0, now), kind: "none", decidedBy, confidence: 1, ...EMPTY_FIELDS };
}

/** Row for a message that the filter rejected. */
export const filterRow = (meta: MessageMeta, email: ReceiptEmail, now: Date) => noneRow(meta, email, "filter", now);

function receiptRow(
  meta: MessageMeta,
  email: ReceiptEmail,
  n: number,
  output: ReceiptOutput,
  modelId: string,
  now: Date,
): ReceiptRow {
  const currency = output.currency?.toUpperCase() ?? null;
  const money = (amount: number | null) => toMinor(amount, currency);
  return {
    ...messageFields(meta, email, n, now),
    kind: output.kind,
    decidedBy: modelId,
    confidence: Math.min(1, Math.max(0, output.confidence)),
    merchant: output.merchant,
    orderId: output.orderId,
    purchaseDate: output.purchaseDate,
    currency,
    total: money(output.total),
    subtotal: money(output.subtotal),
    tax: money(output.tax),
    shippingCost: money(output.shippingCost),
    discount: money(output.discount),
    paymentMethod: output.paymentMethod,
    items: JSON.stringify(
      output.items.map((item) => ({
        description: item.description,
        quantity: item.quantity,
        unitPrice: money(item.unitPrice),
        total: money(item.total),
      })),
    ),
    receiptUrl: output.receiptUrl,
    plan: output.plan,
    periodStart: output.periodStart,
    periodEnd: output.periodEnd,
    nextRenewal: output.nextRenewal,
    carrier: output.carrier,
    trackingNumber: output.trackingNumber,
  };
}

/** Rows for a message that the model read: one for each receipt, or one "none" row when it found none. */
export function modelRows(
  meta: MessageMeta,
  email: ReceiptEmail,
  output: ExtractionOutput,
  modelId: string,
  now: Date,
): ReceiptRow[] {
  if (output.receipts.length === 0) return [noneRow(meta, email, modelId, now)];
  return output.receipts.map((receipt, n) => receiptRow(meta, email, n, receipt, modelId, now));
}
