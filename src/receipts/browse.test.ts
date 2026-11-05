import { describe, expect, it } from "vitest";
import { bestPdf, toBrowseReceipts } from "./browse.ts";

const receipt = (fields: Record<string, unknown> = {}) => ({
  id: "m1:0",
  threadId: "t1",
  date: Date.parse("2026-09-28T15:00:00.000Z"),
  kind: "order",
  subject: "Your order",
  merchant: "Amazon",
  orderId: "112-1234567-1234567",
  purchaseDate: "2026-09-28",
  currency: "USD",
  total: 5214,
  subtotal: 4876,
  tax: 338,
  shippingCost: null,
  discount: null,
  paymentMethod: "Visa ending 1234",
  items: '[{"description":"Power bank","quantity":1,"unitPrice":3299,"total":3299}]',
  plan: null,
  periodStart: null,
  periodEnd: null,
  ...fields,
});

describe("bestPdf", () => {
  const proof = { fidelity: "merchant_page", pdfKey: "proofs/m1/link-0.pdf", emailPdfKey: "proofs/m1/email.pdf" };

  it("prefers the signed-in PDF", () => {
    expect(bestPdf(proof, { pdfKey: "proofs/m1/signed-in-0.pdf" })).toEqual({ key: "proofs/m1/signed-in-0.pdf", kind: "merchant" });
  });

  it("uses a merchant PDF that proves the receipt", () => {
    expect(bestPdf(proof, undefined)).toEqual({ key: "proofs/m1/link-0.pdf", kind: "merchant" });
  });

  it("uses the email PDF when the merchant PDF does not prove the receipt", () => {
    expect(bestPdf({ ...proof, fidelity: "unverified_page" }, { pdfKey: null })).toEqual({ key: "proofs/m1/email.pdf", kind: "email" });
  });

  it("gives null without a proof row", () => {
    expect(bestPdf(undefined, undefined)).toBeNull();
  });
});

describe("toBrowseReceipts", () => {
  it("joins the proofs, parses the items, and sorts newest first", () => {
    const older = receipt({ id: "m0:0", threadId: "t0", date: Date.parse("2026-01-02T00:00:00.000Z"), items: "[]" });
    const rows = toBrowseReceipts(
      [older, receipt()],
      [{ id: "m1:0", fidelity: "login_required", pdfKey: null, emailPdfKey: "proofs/m1/email.pdf" }],
      [{ id: "m1:0", pdfKey: "proofs/m1/signed-in-0.pdf" }],
      "me@example.com",
    );

    expect(rows.map((row) => row.id)).toEqual(["m1:0", "m0:0"]);
    expect(rows[0]).toMatchObject({
      gmailUrl: "https://mail.google.com/mail/?authuser=me%40example.com#all/t1",
      date: "2026-09-28T15:00:00.000Z",
      total: 5214,
      items: [{ description: "Power bank", quantity: 1, unitPrice: 3299, total: 3299 }],
      proof: "merchant",
      hasEmailPdf: true,
    });
    expect(rows[1]).toMatchObject({ proof: null, hasEmailPdf: false });
  });
});
