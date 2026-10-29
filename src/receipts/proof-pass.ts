// Gets the proof of purchase of the receipts of one email: a PDF of the email, its PDF attachments,
// and PDFs of the receipt links that open without a sign-in.

import { createHash } from "node:crypto";
import { selectLinks } from "./links.ts";
import { better, classify, PROVES, WITH_PDF, type Fidelity, type ProofTarget, type Visit } from "./proof.ts";
import type { ProofEmail } from "./proof-email.ts";
import { PROOFS_VERSION, type ProofAttempt, type ProofDocument, type ProofRow } from "./proof-table.ts";

/** A receipt row and the fields that the proof needs. */
export interface ProofReceipt extends ProofTarget {
  id: string;
  messageId: string;
  receiptUrl: string | null;
}

export interface ProofBrowser {
  visit(url: string): Promise<Visit>;
  /** Renders HTML to PDF without scripts. */
  renderPage(html: string): Promise<Uint8Array>;
}

export interface ProofDeps {
  browser: ProofBrowser;
  putPdf(key: string, pdf: Uint8Array): Promise<void>;
  /** Links to open for each email, at most */
  maxLinks: number;
  now: () => Date;
}

const sha256 = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
/** Candidate links for each link that is opened. Links on a site that asked for a sign-in are skipped. */
const CANDIDATES_PER_VISIT = 2;
/** After these, the other links on the same site give the same result. */
const SITE_DEAD_ENDS: ReadonlySet<Fidelity> = new Set(["login_required", "blocked"]);

function hostOf(url: string | null): string | null {
  if (url === null) return null;
  try {
    return new URL(url).host;
  } catch {
    return null;
  }
}

interface Best {
  fidelity: Fidelity;
  attempt: ProofAttempt | null;
  pdfKey: string | null;
}

/** Returns one proof row for each receipt of the message. All receipts must have the same messageId. */
export async function checkMessage(
  messageId: string,
  email: ProofEmail,
  receipts: ProofReceipt[],
  deps: ProofDeps,
): Promise<ProofRow[]> {
  const documents: ProofDocument[] = [];
  const store = async (key: string, pdf: Uint8Array, source: ProofDocument["source"], name: string) => {
    await deps.putPdf(key, pdf);
    documents.push({ key, source, name, sha256: sha256(pdf), bytes: pdf.byteLength });
    return key;
  };

  const emailPdfKey = `proofs/${messageId}/email.pdf`;
  await deps.putPdf(emailPdfKey, await deps.browser.renderPage(email.page));
  for (const [n, pdf] of email.pdfs.entries()) {
    await store(`proofs/${messageId}/attachment-${n}.pdf`, pdf.content, "attachment", pdf.filename);
  }

  const attempts: ProofAttempt[] = [];
  const best = new Map<string, Best>(
    receipts.map((r) => [
      r.id,
      documents[0]
        ? { fidelity: "attached_pdf", attempt: null, pdfKey: documents[0].key }
        : { fidelity: "no_link", attempt: null, pdfKey: null },
    ]),
  );
  const proven = () => [...best.values()].every(({ fidelity }) => PROVES.has(fidelity));

  const urls = selectLinks(
    email.links,
    receipts.flatMap((r) => (r.receiptUrl ? [r.receiptUrl] : [])),
    deps.maxLinks * CANDIDATES_PER_VISIT,
  );
  const deadHosts = new Set<string>();
  for (const [n, url] of urls.entries()) {
    if (proven() || attempts.length >= deps.maxLinks) break;
    if (deadHosts.has(hostOf(url) ?? "")) continue;
    // A visit that throws is a browser failure, not a link failure. The message fails, and the queue tries it again.
    const visit = await deps.browser.visit(url);
    const fidelities = new Map(receipts.map((r) => [r.id, classify(visit, r)]));
    const top = [...fidelities.values()].reduce(better);
    const attempt: ProofAttempt = {
      url,
      fidelity: top,
      status: visit.ok ? visit.status : null,
      finalUrl: visit.ok ? visit.finalUrl : null,
      error: visit.ok ? null : visit.error.slice(0, 300),
    };
    attempts.push(attempt);
    if (SITE_DEAD_ENDS.has(top)) {
      for (const host of [hostOf(url), hostOf(attempt.finalUrl)]) if (host) deadHosts.add(host);
    }
    const pdfKey =
      visit.ok && WITH_PDF.has(top) ? await store(`proofs/${messageId}/link-${n}.pdf`, visit.pdf, "link", url) : null;
    for (const [id, fidelity] of fidelities) {
      const current = best.get(id);
      if (current && fidelity !== current.fidelity && better(fidelity, current.fidelity) === fidelity) {
        best.set(id, { fidelity, attempt, pdfKey: WITH_PDF.has(fidelity) ? pdfKey : current.pdfKey });
      }
    }
  }

  return receipts.map((r) => {
    const { fidelity, attempt, pdfKey } = best.get(r.id) ?? { fidelity: "no_link", attempt: null, pdfKey: null };
    return {
      id: r.id,
      messageId,
      fidelity,
      url: attempt?.url ?? null,
      finalUrl: attempt?.finalUrl ?? null,
      httpStatus: attempt?.status ?? null,
      pdfKey,
      emailPdfKey,
      documents: JSON.stringify(documents),
      attempts: JSON.stringify(attempts),
      checkedAt: deps.now(),
      version: PROOFS_VERSION,
    };
  });
}
