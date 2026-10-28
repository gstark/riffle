import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { MAX_INPUT_CHARS, modelInput, parseReceipt, ReceiptSchema } from "./extract-receipt.ts";
import { receiptOutput } from "./test-fakes.ts";

describe("modelInput", () => {
  it("starts with the sender, subject, and receive time", () => {
    const input = modelInput({ from: "Amazon <a@amazon.com>", subject: "Your order", text: "Total $5" }, meta("a"));

    expect(input).toBe(
      "From: Amazon <a@amazon.com>\nSubject: Your order\nReceived: 2024-03-09T00:00:00.000Z\n\nTotal $5",
    );
  });

  it("cuts the body text", () => {
    const input = modelInput({ from: "x", subject: "y", text: "a".repeat(MAX_INPUT_CHARS + 500) }, meta("a"));

    expect(input.endsWith(`\n\n${"a".repeat(MAX_INPUT_CHARS)}`)).toBe(true);
  });
});

describe("ReceiptSchema", () => {
  it("accepts a complete output", () => {
    expect(ReceiptSchema.parse(receiptOutput())).toEqual(receiptOutput());
  });

  it("rejects a date that is not ISO 8601", () => {
    expect(ReceiptSchema.safeParse(receiptOutput({ purchaseDate: "March 9" })).success).toBe(false);
  });

  it("gives the model a description on each field, without $ref", () => {
    const schema = zodOutputFormat(ReceiptSchema).schema as {
      properties: Record<string, { description?: string }>;
    };

    expect(schema.properties.merchant?.description).toContain("Merchant name");
    expect(schema.properties.purchaseDate?.description).toContain("Date of the purchase");
    expect(schema.properties.total?.description).toContain("Decimal amount");
    expect(JSON.stringify(schema)).not.toContain("$ref");
  });
});

describe("parseReceipt", () => {
  it("reads missing fields as null and a missing item list as empty", () => {
    expect(parseReceipt({ kind: "none", confidence: 0.8 })).toEqual(
      receiptOutput({
        kind: "none",
        confidence: 0.8,
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
        items: [],
        receiptUrl: null,
      }),
    );
  });

  it("reads missing item fields as null", () => {
    expect(parseReceipt({ ...receiptOutput(), items: [{ description: "Cable" }] }).items).toEqual([
      { description: "Cable", quantity: null, unitPrice: null, total: null },
    ]);
  });

  it("reads a missing confidence as 0", () => {
    expect(parseReceipt({ kind: "none" }).confidence).toBe(0);
  });

  it("rejects output without a kind", () => {
    expect(() => parseReceipt({ confidence: 1 })).toThrow();
  });
});
