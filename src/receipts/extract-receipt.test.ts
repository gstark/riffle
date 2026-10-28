import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { ExtractionSchema, MAX_INPUT_CHARS, modelInput, parseExtraction, ReceiptSchema } from "./extract-receipt.ts";
import { extraction, receiptOutput } from "./test-fakes.ts";

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
    const schema = zodOutputFormat(ExtractionSchema).schema as {
      properties: { receipts: { description?: string; items: { properties: Record<string, { description?: string }> } } };
    };
    const receipt = schema.properties.receipts.items.properties;

    expect(schema.properties.receipts.description).toContain("One receipt for each");
    expect(receipt.merchant?.description).toContain("Merchant name");
    expect(receipt.purchaseDate?.description).toContain("Date of the purchase");
    expect(receipt.total?.description).toContain("Decimal amount");
    expect(JSON.stringify(schema)).not.toContain("$ref");
  });
});

describe("parseExtraction", () => {
  it("reads missing fields as null and a missing item list as empty", () => {
    expect(parseExtraction({ receipts: [{ kind: "shipping", confidence: 0.8 }] })).toEqual(
      extraction(
        receiptOutput({
          kind: "shipping",
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
      ),
    );
  });

  it("reads missing item fields as null", () => {
    const output = parseExtraction({ receipts: [{ ...receiptOutput(), items: [{ description: "Cable" }] }] });

    expect(output.receipts[0]?.items).toEqual([{ description: "Cable", quantity: null, unitPrice: null, total: null }]);
  });

  it("reads a missing confidence as 0", () => {
    expect(parseExtraction({ receipts: [{ kind: "order" }] }).receipts[0]?.confidence).toBe(0);
  });

  it("reads a receipts list that is a JSON string", () => {
    expect(parseExtraction({ receipts: JSON.stringify([receiptOutput()]) })).toEqual(extraction(receiptOutput()));
  });

  it("accepts an empty list", () => {
    expect(parseExtraction({ receipts: [] })).toEqual(extraction());
  });

  it("rejects output without a receipts list, a receipt without a kind, and an unknown kind", () => {
    expect(() => parseExtraction({ kind: "order" })).toThrow();
    expect(() => parseExtraction({ receipts: [{ confidence: 1 }] })).toThrow();
    expect(() => parseExtraction({ receipts: [{ kind: "payment" }] })).toThrow();
  });
});
