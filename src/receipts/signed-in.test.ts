import { describe, expect, it } from "vitest";
import { BadRequestError } from "../search/request.ts";
import {
  createSignedInProofs,
  groupBySite,
  printUrl,
  siteKey,
  type Candidate,
  type PageResult,
  type SignedInRow,
} from "./signed-in.ts";

function candidate(fields: Partial<Candidate> = {}): Candidate {
  return {
    id: "m1:0",
    messageId: "m1",
    date: new Date("2026-03-09T12:00:00Z"),
    subject: "Your order",
    merchant: "Uber",
    orderId: null,
    total: 2345,
    currency: "USD",
    url: "https://click.uber.com/receipt/abc",
    finalUrl: "https://auth.uber.com/login?next=x",
    ...fields,
  };
}

const amazon = (fields: Partial<Candidate> = {}) =>
  candidate({
    merchant: "Amazon.com",
    orderId: "112-1234567-1234567",
    url: null,
    finalUrl: null,
    ...fields,
  });

describe("siteKey", () => {
  it.each<[string, Partial<Candidate>, string | null]>([
    ["the last two parts of the final host", {}, "uber.com"],
    ["the link host when there is no final address", { finalUrl: null }, "uber.com"],
    ["lower case", { finalUrl: "https://ID.Heroku.COM/login" }, "heroku.com"],
    ["null without a link", { url: null, finalUrl: null }, null],
    ["null for a bad address", { url: "not a url", finalUrl: null }, null],
  ])("%s", (_, fields, expected) => {
    expect(siteKey(candidate(fields))).toBe(expected);
  });

  it("is amazon.com for an Amazon order, whatever the link", () => {
    expect(siteKey(amazon({ finalUrl: "https://email.amazon.co.uk/x" }))).toBe("amazon.com");
  });

  it("uses the link for Amazon without an Amazon order ID", () => {
    expect(siteKey(amazon({ orderId: "D01-1234", url: "https://www.amazon.com/x" }))).toBe("amazon.com");
    expect(siteKey(amazon({ orderId: null }))).toBeNull();
  });
});

describe("printUrl", () => {
  it("is the invoice of the first Amazon order", () => {
    expect(printUrl(amazon({ orderId: "112-1234567-1234567, 113-7654321-7654321" }))).toBe(
      "https://www.amazon.com/gp/css/summary/print.html?orderID=112-1234567-1234567",
    );
  });

  it("is the receipt link for other merchants", () => {
    expect(printUrl(candidate())).toBe("https://click.uber.com/receipt/abc");
  });
});

describe("groupBySite", () => {
  it("groups by site, largest site first, newest receipt first", () => {
    const sites = groupBySite([
      candidate({ id: "u1:0", messageId: "u1", date: new Date("2026-01-01T00:00:00Z") }),
      amazon({ id: "a1:0", messageId: "a1", date: new Date("2026-01-01T00:00:00Z") }),
      amazon({ id: "a2:0", messageId: "a2", date: new Date("2026-02-01T00:00:00Z"), merchant: "Amazon" }),
      amazon({ id: "a3:0", messageId: "a3", date: new Date("2026-03-01T00:00:00Z") }),
      candidate({ id: "x:0", url: null, finalUrl: null }),
    ]);

    expect(sites.map((s) => [s.site, s.merchant, s.receipts.map((r) => r.id)])).toEqual([
      ["amazon.com", "Amazon.com", ["a3:0", "a2:0", "a1:0"]],
      ["uber.com", "Uber", ["u1:0"]],
    ]);
    expect(sites[1]?.receipts[0]).toEqual({
      id: "u1:0",
      messageId: "u1",
      date: "2026-01-01T00:00:00.000Z",
      subject: "Your order",
      merchant: "Uber",
      orderId: null,
      total: 2345,
      currency: "USD",
      url: "https://click.uber.com/receipt/abc",
      printUrl: "https://click.uber.com/receipt/abc",
    });
  });

  it("names a site without merchants after the site", () => {
    expect(groupBySite([candidate({ merchant: null })])[0]?.merchant).toBe("uber.com");
  });
});

function setup({ found = candidate(), uploaded = true } = {}) {
  const written: SignedInRow[] = [];
  const now = new Date("2026-10-29T12:00:00Z");
  const proofs = createSignedInProofs({
    pending: async () => [found],
    candidate: async (id) => (id === found.id ? found : null),
    presignPut: async (key, sha256) => `https://s3.example.com/${key}?sha256=${sha256}`,
    pdfExists: async () => uploaded,
    write: async (row) => {
      written.push(row);
    },
    now: () => now,
  });
  return { proofs, written, now };
}

const page = (fields: Partial<PageResult> = {}): PageResult => ({
  id: "m1:0",
  finalUrl: "https://riders.uber.com/trips/abc",
  status: 200,
  hasPasswordField: false,
  text: "Total $23.45",
  ...fields,
});

describe("createSignedInProofs", () => {
  it("lists the pending receipts by site", async () => {
    const { proofs } = setup();
    expect((await proofs.pending()).map((s) => s.site)).toEqual(["uber.com"]);
  });

  it("gives an upload URL for the signed-in PDF of the receipt", async () => {
    const { proofs } = setup({ found: candidate({ id: "m1:2" }) });
    expect(await proofs.upload("m1:2", "abc=")).toEqual({
      url: "https://s3.example.com/proofs/m1/signed-in-2.pdf?sha256=abc=",
      key: "proofs/m1/signed-in-2.pdf",
    });
  });

  it("refuses a receipt that does not need a signed-in proof", async () => {
    const { proofs } = setup();
    await expect(proofs.upload("other:0", "abc=")).rejects.toThrow(BadRequestError);
    await expect(proofs.result(page({ id: "other:0" }))).rejects.toThrow(BadRequestError);
  });

  it("writes a page that shows the receipt", async () => {
    const { proofs, written, now } = setup();
    expect(await proofs.result(page())).toEqual({ fidelity: "merchant_page" });
    expect(written).toEqual([
      {
        id: "m1:0",
        messageId: "m1",
        site: "uber.com",
        fidelity: "merchant_page",
        url: "https://click.uber.com/receipt/abc",
        finalUrl: "https://riders.uber.com/trips/abc",
        httpStatus: 200,
        pdfKey: "proofs/m1/signed-in-0.pdf",
        checkedAt: now,
      },
    ]);
  });

  it("writes a page without the total as unverified", async () => {
    const { proofs, written } = setup();
    expect(await proofs.result(page({ text: "Your trips" }))).toEqual({ fidelity: "unverified_page" });
    expect(written[0]?.fidelity).toBe("unverified_page");
  });

  it.each<[string, Partial<PageResult>, string]>([
    ["a sign-in page", { hasPasswordField: true }, "login_required"],
    ["a robot check", { text: "Are you a robot?" }, "blocked"],
    ["an error page", { status: 404 }, "link_failed"],
  ])("does not write %s, so the receipt stays pending", async (_, fields, fidelity) => {
    const { proofs, written } = setup();
    expect(await proofs.result(page(fields))).toEqual({ fidelity });
    expect(written).toEqual([]);
  });

  it("refuses a result before the PDF is uploaded", async () => {
    const { proofs, written } = setup({ uploaded: false });
    await expect(proofs.result(page())).rejects.toThrow("Upload the PDF of receipt m1:0 first");
    expect(written).toEqual([]);
  });
});
