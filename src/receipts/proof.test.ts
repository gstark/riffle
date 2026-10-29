import { describe, expect, it } from "vitest";
import { amountTexts, classify, showsReceipt, type Visit } from "./proof.ts";

const target = { total: 123456, currency: "USD", orderId: "113-1234567-7654321" };
const page = (fields: Partial<Extract<Visit, { ok: true }>>): Visit => ({
  ok: true,
  status: 200,
  finalUrl: "https://shop.example/receipt/1",
  pdf: new Uint8Array([1]),
  download: false,
  hasPasswordField: false,
  text: "Thanks for your order",
  ...fields,
});

describe("amountTexts", () => {
  it.each<[number, string | null, string[]]>([
    [123456, "USD", ["1234.56", "1,234.56"]],
    [1390, "USD", ["13.90"]],
    [1500, "JPY", ["1500", "1,500"]],
    [999, null, ["9.99"]],
  ])("writes %d %s", (minor, currency, expected) => {
    expect(amountTexts(minor, currency)).toEqual(expected);
  });
});

describe("showsReceipt", () => {
  it("finds the total", () => {
    expect(showsReceipt("Order total: $1,234.56", target)).toBe(true);
  });

  it("finds one of several order IDs", () => {
    expect(showsReceipt("Order #222-1", { ...target, total: null, orderId: "111-0, 222-1" })).toBe(true);
  });

  it("ignores short order IDs", () => {
    expect(showsReceipt("Item 12 of 30", { total: null, currency: null, orderId: "12" })).toBe(false);
  });

  it("is false when the page shows neither", () => {
    expect(showsReceipt("Help center", target)).toBe(false);
  });
});

describe("classify", () => {
  it.each<[string, Visit, string]>([
    ["a failed visit", { ok: false, error: "timeout" }, "link_failed"],
    ["a PDF download", page({ download: true, status: null }), "merchant_pdf"],
    ["a page with the total", page({ text: "Total $1,234.56" }), "merchant_page"],
    ["a page without receipt data", page({}), "unverified_page"],
    ["status 401", page({ status: 401 }), "login_required"],
    ["a password field", page({ hasPasswordField: true }), "login_required"],
    ["a sign-in redirect", page({ finalUrl: "https://www.amazon.com/ap/signin?x=1" }), "login_required"],
    ["a sign-in host", page({ status: 403, finalUrl: "https://auth.uber.com/v2/?x=1" }), "login_required"],
    ["status 403", page({ status: 403 }), "blocked"],
    ["status 503", page({ status: 503 }), "blocked"],
    ["a CAPTCHA", page({ text: "Please complete the CAPTCHA" }), "blocked"],
    ["status 404", page({ status: 404 }), "link_failed"],
    ["an expired link", page({ text: "This link expired. To get a new link contact us." }), "link_failed"],
  ])("classifies %s", (_, visit, expected) => {
    expect(classify(visit, target)).toBe(expected);
  });
});
