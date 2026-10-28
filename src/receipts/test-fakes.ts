// Test helpers for the receipts code.

import type { ReceiptOutput } from "./extract-receipt.ts";

/** A complete Amazon order output. Override fields as needed. */
export function receiptOutput(fields: Partial<ReceiptOutput> = {}): ReceiptOutput {
  return {
    kind: "order",
    confidence: 0.9,
    merchant: "Amazon",
    orderId: "112-1234567-1234567",
    purchaseDate: "2024-03-09",
    currency: "USD",
    total: 23.45,
    subtotal: 21.5,
    tax: 1.95,
    shippingCost: 0,
    discount: null,
    paymentMethod: "Visa ending 1234",
    items: [{ description: "USB cable", quantity: 1, unitPrice: 21.5, total: 21.5 }],
    receiptUrl: "https://www.amazon.com/gp/your-account/order-details?orderID=112-1234567-1234567",
    plan: null,
    periodStart: null,
    periodEnd: null,
    nextRenewal: null,
    carrier: null,
    trackingNumber: null,
    ...fields,
  };
}
