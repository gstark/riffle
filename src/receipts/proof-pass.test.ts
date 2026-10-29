import { describe, expect, it } from "vitest";
import type { Visit } from "./proof.ts";
import { checkMessage, type ProofReceipt } from "./proof-pass.ts";
import type { ProofEmail } from "./proof-email.ts";

const now = new Date("2026-10-28T12:00:00Z");
const receipt = (n: number, fields: Partial<ProofReceipt> = {}): ProofReceipt => ({
  id: `m:${n}`,
  messageId: "m",
  total: 1390,
  currency: "USD",
  orderId: null,
  receiptUrl: null,
  ...fields,
});
const page = (text: string, fields: Partial<Extract<Visit, { ok: true }>> = {}): Visit => ({
  ok: true,
  status: 200,
  finalUrl: "https://shop.example/r",
  pdf: new Uint8Array([37, 80, 68, 70]),
  download: false,
  hasPasswordField: false,
  text,
  ...fields,
});
const email = (fields: Partial<ProofEmail> = {}): ProofEmail => ({
  page: "<p>email</p>",
  links: [],
  pdfs: [],
  ...fields,
});

function fakes(pages: Record<string, Visit>) {
  const visited: string[] = [];
  const stored = new Map<string, Uint8Array>();
  const deps = {
    browser: {
      visit: async (url: string) => {
        visited.push(url);
        return pages[url] ?? { ok: false as const, error: "no page" };
      },
      renderPage: async () => new Uint8Array([1, 2]),
    },
    putPdf: async (key: string, pdf: Uint8Array) => {
      stored.set(key, pdf);
    },
    maxLinks: 3,
    now: () => now,
  };
  return { deps, visited, stored };
}

describe("checkMessage", () => {
  it("stores the email PDF and the attachments, and opens no links when there is a PDF attachment", async () => {
    const { deps, visited, stored } = fakes({});
    const [row] = await checkMessage(
      "m",
      email({
        pdfs: [{ filename: "invoice.pdf", content: new Uint8Array([9]) }],
        links: [{ url: "https://shop.example/receipt", text: "View receipt" }],
      }),
      [receipt(0)],
      deps,
    );

    expect(visited).toEqual([]);
    expect([...stored.keys()]).toEqual(["proofs/m/email.pdf", "proofs/m/attachment-0.pdf"]);
    expect(row).toMatchObject({
      fidelity: "attached_pdf",
      pdfKey: "proofs/m/attachment-0.pdf",
      emailPdfKey: "proofs/m/email.pdf",
    });
    expect(JSON.parse(row?.documents ?? "")).toEqual([
      expect.objectContaining({ source: "attachment", name: "invoice.pdf", bytes: 1 }),
    ]);
  });

  it("opens links until one proves the receipt", async () => {
    const { deps, visited, stored } = fakes({
      "https://shop.example/invoice": page("Sign in", { finalUrl: "https://shop.example/signin" }),
      "https://click.example/r": page("Total $13.90"),
      "https://shop.example/more": page("Total $13.90"),
    });
    const links = [
      { url: "https://shop.example/invoice", text: "Invoice" },
      { url: "https://click.example/r", text: "View receipt" },
      { url: "https://shop.example/more", text: "Receipt" },
    ];
    const [row] = await checkMessage("m", email({ links }), [receipt(0)], deps);

    expect(visited).toEqual(["https://shop.example/invoice", "https://click.example/r"]);
    expect([...stored.keys()]).toEqual(["proofs/m/email.pdf", "proofs/m/link-1.pdf"]);
    expect(row).toMatchObject({
      fidelity: "merchant_page",
      url: "https://click.example/r",
      httpStatus: 200,
      pdfKey: "proofs/m/link-1.pdf",
      version: 1,
      checkedAt: now,
    });
    expect(JSON.parse(row?.attempts ?? "").map((a: { fidelity: string }) => a.fidelity)).toEqual([
      "login_required",
      "merchant_page",
    ]);
  });

  it("skips the other links on a site that asked for a sign-in", async () => {
    const { deps, visited } = fakes({
      "https://shop.example/orders/1": page("Sign in", { finalUrl: "https://shop.example/signin" }),
    });
    const links = [
      { url: "https://shop.example/orders/1", text: "Order details" },
      { url: "https://shop.example/invoice/1", text: "Invoice" },
      { url: "https://other.example/receipt", text: "Receipt" },
    ];
    const [row] = await checkMessage("m", email({ links }), [receipt(0)], deps);

    expect(visited).toEqual(["https://shop.example/orders/1", "https://other.example/receipt"]);
    expect(row?.fidelity).toBe("login_required");
  });

  it("gives each receipt of the email its own fidelity", async () => {
    const { deps } = fakes({ "https://shop.example/orders": page("Order total $13.90") });
    const rows = await checkMessage(
      "m",
      email({ links: [{ url: "https://shop.example/orders", text: "Order details" }] }),
      [receipt(0), receipt(1, { total: 1202 })],
      deps,
    );

    expect(rows.map((row) => [row.id, row.fidelity, row.pdfKey])).toEqual([
      ["m:0", "merchant_page", "proofs/m/link-0.pdf"],
      ["m:1", "unverified_page", "proofs/m/link-0.pdf"],
    ]);
  });

  it("records no_link when no link can be a receipt", async () => {
    const { deps } = fakes({});
    const [none] = await checkMessage(
      "m",
      email({ links: [{ url: "https://shop.example/", text: "" }] }),
      [receipt(0)],
      deps,
    );
    expect(none).toMatchObject({ fidelity: "no_link", url: null, pdfKey: null, attempts: "[]" });
  });

  it("fails the message when the browser throws, so the queue tries it again", async () => {
    const { deps } = fakes({});
    const check = checkMessage("m", email(), [receipt(0, { receiptUrl: "https://shop.example/r/1" })], {
      ...deps,
      browser: { ...deps.browser, visit: () => Promise.reject(new Error("browser closed")) },
    });
    await expect(check).rejects.toThrow("browser closed");
  });
});
