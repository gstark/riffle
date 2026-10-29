import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import * as lancedb from "@lancedb/lancedb";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import type { Fidelity } from "./proof.ts";
import { openOrCreateProofs, PROOFS_VERSION, replaceProofs, type ProofRow } from "./proof-table.ts";
import { modelRows } from "./row.ts";
import { openCandidateTables, readCandidates, writeSignedIn } from "./signed-in-table.ts";
import type { SignedInRow } from "./signed-in.ts";
import { openOrCreateReceipts, replaceReceipts } from "./table.ts";
import { extraction, receiptOutput } from "./test-fakes.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "signed-in-table-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const now = new Date("2026-10-29T12:00:00Z");

const proof = (messageId: string, fidelity: Fidelity): ProofRow => ({
  id: `${messageId}:0`,
  messageId,
  fidelity,
  url: `https://example.com/${messageId}`,
  finalUrl: `https://login.example.com/${messageId}`,
  httpStatus: 200,
  pdfKey: null,
  emailPdfKey: `proofs/${messageId}/email.pdf`,
  documents: "[]",
  attempts: "[]",
  checkedAt: now,
  version: PROOFS_VERSION,
});

const signedIn = (messageId: string): SignedInRow => ({
  id: `${messageId}:0`,
  messageId,
  site: "example.com",
  fidelity: "merchant_page",
  url: `https://example.com/${messageId}`,
  finalUrl: `https://example.com/${messageId}`,
  httpStatus: 200,
  pdfKey: `proofs/${messageId}/signed-in-0.pdf`,
  checkedAt: now,
});

const order = (id: string, orderId: string) =>
  modelRows(meta(id), { from: "x", subject: `Order ${id}`, text: "z" }, extraction(receiptOutput({ orderId })), "m", now);

async function setup() {
  const ids = ["login", "blocked", "done", "page"];
  const receipts = await openOrCreateReceipts(dir);
  await replaceReceipts(
    receipts,
    ids,
    ids.flatMap((id) => order(id, `order-${id}`)),
  );
  const proofs = await openOrCreateProofs(dir);
  await replaceProofs(proofs, ids, [
    proof("login", "login_required"),
    proof("blocked", "blocked"),
    proof("done", "login_required"),
    proof("page", "merchant_page"),
  ]);
  const tables = await openCandidateTables(await lancedb.connect(dir));
  await writeSignedIn(tables.signedIn, signedIn("done"));
  return tables;
}

describe("signed-in proofs table", () => {
  it("reads the pending receipts with their receipt data and links", async () => {
    const candidates = await readCandidates(await setup());

    expect(candidates.map((c) => c.id).toSorted()).toEqual(["blocked:0", "login:0"]);
    expect(candidates.find((c) => c.id === "login:0")).toMatchObject({
      messageId: "login",
      subject: "Order login",
      merchant: "Amazon",
      orderId: "order-login",
      total: 2345,
      currency: "USD",
      url: "https://example.com/login",
      finalUrl: "https://login.example.com/login",
      sharedLink: false,
    });
    expect(candidates[0]?.date).toBeInstanceOf(Date);
  });

  it("reads one receipt also when it has a signed-in row, but not a receipt with a good proof", async () => {
    const tables = await setup();
    expect((await readCandidates(tables, "done:0")).map((c) => c.id)).toEqual(["done:0"]);
    expect(await readCandidates(tables, "page:0")).toEqual([]);
  });

  it("marks a link that the email of another receipt also has", async () => {
    const tables = await setup();
    // "page" has a good proof, but its email has the same link as "login".
    await replaceProofs(tables.proofs, ["page"], [{ ...proof("page", "merchant_page"), url: "https://example.com/login" }]);

    const candidates = await readCandidates(tables);
    expect(candidates.find((c) => c.id === "login:0")?.sharedLink).toBe(true);
    expect(candidates.find((c) => c.id === "blocked:0")?.sharedLink).toBe(false);
  });

  it("does not mark a link that a forwarded email of the same order also has", async () => {
    const tables = await setup();
    await replaceReceipts(tables.receipts, ["page"], order("page", "order-login"));
    await replaceProofs(tables.proofs, ["page"], [{ ...proof("page", "merchant_page"), url: "https://example.com/login" }]);

    const candidates = await readCandidates(tables);
    expect(candidates.find((c) => c.id === "login:0")?.sharedLink).toBe(false);
  });

  it("writes a wrong page without a PDF", async () => {
    const tables = await setup();
    await writeSignedIn(tables.signedIn, { ...signedIn("login"), fidelity: "wrong_page", pdfKey: null });
    const rows = await tables.signedIn.query().where("id = 'login:0'").toArray();
    expect(rows[0]).toMatchObject({ fidelity: "wrong_page", pdfKey: null });
  });

  it("replaces the row of a receipt", async () => {
    const tables = await setup();
    await writeSignedIn(tables.signedIn, { ...signedIn("done"), fidelity: "unverified_page" });
    const rows = await tables.signedIn.query().toArray();
    expect(rows.map((row: Record<string, unknown>) => [row.id, row.fidelity])).toEqual([["done:0", "unverified_page"]]);
  });
});
