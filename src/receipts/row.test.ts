import { describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { filterRow, modelRows, RECEIPTS_VERSION, toMinor } from "./row.ts";
import { extraction, receiptOutput } from "./test-fakes.ts";

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

describe("modelRows", () => {
  it("copies the output with amounts in minor units", () => {
    const [row] = modelRows(meta("a"), email, extraction(receiptOutput({ currency: "usd" })), "model-x", now);

    expect(row).toMatchObject({
      id: "a:0",
      messageId: "a",
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
    expect(JSON.parse(row?.items ?? "")).toEqual([
      { description: "USB cable", quantity: 1, unitPrice: 2150, total: 2150 },
    ]);
  });

  it("gives each receipt of a message its own row", () => {
    const output = extraction(receiptOutput({ orderId: "1", total: 12.02 }), receiptOutput({ orderId: "2", total: 13.9 }));

    const rows = modelRows(meta("a"), email, output, "m", now);

    expect(rows.map(({ id, messageId, orderId, total }) => ({ id, messageId, orderId, total }))).toEqual([
      { id: "a:0", messageId: "a", orderId: "1", total: 1202 },
      { id: "a:1", messageId: "a", orderId: "2", total: 1390 },
    ]);
  });

  it("gives a message without receipts one none row", () => {
    const rows = modelRows(meta("a"), email, extraction(), "m", now);

    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ id: "a:0", messageId: "a", kind: "none", decidedBy: "m", total: null });
  });

  it("keeps confidence between 0 and 1", () => {
    const confidence = (value: number) =>
      modelRows(meta("a"), email, extraction(receiptOutput({ confidence: value })), "m", now)[0]?.confidence;

    expect(confidence(7)).toBe(1);
    expect(confidence(-1)).toBe(0);
  });
});

describe("filterRow", () => {
  it("records a message that the filter rejected", () => {
    const row = filterRow(meta("a"), email, now);

    expect(row).toMatchObject({
      id: "a:0",
      messageId: "a",
      kind: "none",
      decidedBy: "filter",
      confidence: 1,
      version: RECEIPTS_VERSION,
    });
    expect(row.items).toBe("[]");
    expect(row.total).toBeNull();
    expect(row.receiptUrl).toBeNull();
  });
});
