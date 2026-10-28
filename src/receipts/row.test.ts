import { describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { filterRow, modelRow, RECEIPTS_VERSION, toMinor } from "./row.ts";
import { receiptOutput } from "./test-fakes.ts";

const email = { from: "Amazon <a@amazon.com>", subject: "Your order", text: "Total $23.45" };
const now = new Date("2026-10-28T12:00:00Z");

describe("toMinor", () => {
  it.each<[number | null, string | null, number | null]>([
    [12.99, "USD", 1299],
    [19.99, "USD", 1999],
    [1500, "JPY", 1500],
    [1.234, "KWD", 1234],
    [-5, "USD", 500],
    [12.5, null, 1250],
    [12.5, "not a code", 1250],
    [null, "USD", null],
    [21_474_836.47, "USD", 2_147_483_647],
    [21_474_836.48, "USD", null],
  ])("converts %s %s to %s", (amount, currency, expected) => {
    expect(toMinor(amount, currency)).toBe(expected);
  });
});

describe("modelRow", () => {
  it("copies the output with amounts in minor units", () => {
    const row = modelRow(meta("a"), email, receiptOutput({ currency: "usd" }), "model-x", now);

    expect(row).toMatchObject({
      id: "a",
      threadId: "t-a",
      date: new Date("2024-03-09T00:00:00.000Z"),
      from: "Amazon <a@amazon.com>",
      subject: "Your order",
      kind: "order",
      decidedBy: "model-x",
      version: RECEIPTS_VERSION,
      confidence: 0.9,
      extractedAt: now,
      merchant: "Amazon",
      orderId: "112-1234567-1234567",
      purchaseDate: "2024-03-09",
      currency: "USD",
      total: 2345,
      subtotal: 2150,
      tax: 195,
      shippingCost: 0,
      discount: null,
      paymentMethod: "Visa ending 1234",
    });
    expect(JSON.parse(row.items)).toEqual([{ description: "USB cable", quantity: 1, unitPrice: 2150, total: 2150 }]);
  });

  it("keeps confidence between 0 and 1", () => {
    expect(modelRow(meta("a"), email, receiptOutput({ confidence: 7 }), "m", now).confidence).toBe(1);
    expect(modelRow(meta("a"), email, receiptOutput({ confidence: -1 }), "m", now).confidence).toBe(0);
  });
});

describe("filterRow", () => {
  it("records a message that the filter rejected", () => {
    const row = filterRow(meta("a"), email, now);

    expect(row).toMatchObject({ id: "a", kind: "none", decidedBy: "filter", confidence: 1, version: RECEIPTS_VERSION });
    expect(row.items).toBe("[]");
    expect(row.total).toBeNull();
    expect(row.receiptUrl).toBeNull();
  });
});
