// Proofs that the Riffle app makes on the Mac, in a browser with your sign-in, for the receipts whose link needs a
// sign-in or blocks the AgentCore Browser. The search Lambda serves these routes. See
// docs/superpowers/specs/2026-10-29-signed-in-proofs-design.md.

import { BadRequestError } from "../search/request.ts";
import { classify, type Fidelity } from "./proof.ts";

/** Fidelities of `receipt_proofs` that the Riffle app can make better with a sign-in. */
export const PENDING_FIDELITIES: readonly Fidelity[] = ["login_required", "blocked"];
/** Fidelities that write a signed-in row. Other results leave the receipt pending. */
const WRITTEN: ReadonlySet<Fidelity> = new Set(["merchant_page", "unverified_page"]);

const AMAZON_ORDER_ID = /\b\d{3}-\d{7}-\d{7}\b/;

/** A receipt with a `login_required` or `blocked` proof: fields of the receipt row and of its proof row. */
export interface Candidate {
  id: string;
  messageId: string;
  date: Date;
  subject: string;
  merchant: string | null;
  orderId: string | null;
  /** Minor units of `currency` */
  total: number | null;
  currency: string | null;
  url: string | null;
  finalUrl: string | null;
  /** True when emails of other receipts have the same link. Then the link cannot go to the page of this receipt. */
  sharedLink: boolean;
}

export interface PendingReceipt {
  id: string;
  messageId: string;
  /** ISO 8601 */
  date: string;
  subject: string;
  merchant: string | null;
  orderId: string | null;
  total: number | null;
  currency: string | null;
  /** The receipt link of the email, where you sign in */
  url: string | null;
  /** The page that Riffle prints */
  printUrl: string;
}

export interface PendingSite {
  site: string;
  /** The most frequent merchant name of the receipts, or the site */
  merchant: string;
  receipts: PendingReceipt[];
}

/** One row of the `signed_in_proofs` table. */
export type SignedInRow = {
  id: string;
  messageId: string;
  site: string;
  fidelity: Fidelity;
  /** The page that Riffle printed */
  url: string;
  finalUrl: string;
  httpStatus: number | null;
  /** Null for a `wrong_page` */
  pdfKey: string | null;
  checkedAt: Date;
};

/** What the Riffle app saw on the printed page. */
export interface PageResult {
  id: string;
  finalUrl: string;
  status: number | null;
  hasPasswordField: boolean;
  text: string;
  /** The printed page. The Riffle app prints only a page that shows the total or the order ID. */
  pdf: Uint8Array | null;
}

export interface SignedInDeps {
  /** Receipts with a `login_required` or `blocked` proof and no signed-in row. */
  pending: () => Promise<Candidate[]>;
  /** The receipt with this ID when its proof is `login_required` or `blocked`, with or without a signed-in row. */
  candidate: (id: string) => Promise<Candidate | null>;
  /** Writes a PDF to the archive bucket. */
  putPdf: (key: string, pdf: Uint8Array) => Promise<void>;
  write: (row: SignedInRow) => Promise<void>;
  now: () => Date;
}

const amazonOrderId = (candidate: Candidate): string | null =>
  /amazon/i.test(candidate.merchant ?? "") ? (candidate.orderId?.match(AMAZON_ORDER_ID)?.[0] ?? null) : null;

function host(url: string | null): string | null {
  if (!url) return null;
  try {
    return new URL(url).hostname.toLowerCase() || null;
  } catch {
    return null;
  }
}

/**
 * Links that go to no single receipt: the emails of two or more different orders have them, for example a billing
 * page in each monthly bill. A receipt without an order ID counts as its own order. A forwarded email has the same
 * order as the original, so it does not make the link shared.
 */
export function sharedLinks(proofs: { messageId: string; url: string | null; orderId: string | null }[]): Set<string> {
  const orders = new Map<string, Set<string>>();
  for (const { messageId, url, orderId } of proofs) {
    if (url) orders.set(url, (orders.get(url) ?? new Set()).add(orderId ?? `message:${messageId}`));
  }
  return new Set([...orders].filter(([, keys]) => keys.size >= 2).map(([url]) => url));
}

/** The site of the session that the receipt needs, for example "amazon.com". Null when the receipt has no link. */
export function siteKey(candidate: Candidate): string | null {
  if (amazonOrderId(candidate)) return "amazon.com";
  const name = host(candidate.finalUrl) ?? host(candidate.url);
  return name ? name.split(".").slice(-2).join(".") : null;
}

/**
 * The page that Riffle prints: the Amazon invoice of the order, or the receipt link. Null when the link is shared
 * with other receipts.
 */
export function printUrl(candidate: Candidate): string | null {
  const orderId = amazonOrderId(candidate);
  if (orderId) return `https://www.amazon.com/gp/css/summary/print.html?orderID=${orderId}`;
  return candidate.sharedLink ? null : candidate.url;
}

/** Key of the signed-in PDF of receipt "<messageId>:<n>" in the archive bucket. */
export const signedInPdfKey = (candidate: Candidate): string =>
  `proofs/${candidate.messageId}/signed-in-${candidate.id.split(":").at(-1)}.pdf`;

function mostFrequent(values: string[]): string | undefined {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts].toSorted((a, b) => b[1] - a[1])[0]?.[0];
}

/** Groups the receipts by site. Largest site first, and newest receipt first in each site. */
export function groupBySite(candidates: Candidate[]): PendingSite[] {
  const sites = new Map<string, PendingReceipt[]>();
  const merchants = new Map<string, string[]>();
  for (const c of candidates.toSorted((a, b) => b.date.getTime() - a.date.getTime())) {
    const site = siteKey(c);
    const url = printUrl(c);
    if (!site || !url) continue;
    const { id, messageId, subject, merchant, orderId, total, currency } = c;
    const receipt = { id, messageId, date: c.date.toISOString(), subject, merchant, orderId, total, currency, url: c.url, printUrl: url };
    sites.set(site, [...(sites.get(site) ?? []), receipt]);
    if (merchant) merchants.set(site, [...(merchants.get(site) ?? []), merchant]);
  }
  return [...sites]
    .map(([site, receipts]) => ({ site, merchant: mostFrequent(merchants.get(site) ?? []) ?? site, receipts }))
    .toSorted((a, b) => b.receipts.length - a.receipts.length || a.site.localeCompare(b.site));
}

export function createSignedInProofs(deps: SignedInDeps) {
  async function find(id: string): Promise<Candidate & { site: string; printUrl: string }> {
    const candidate = await deps.candidate(id);
    const site = candidate && siteKey(candidate);
    const url = candidate && printUrl(candidate);
    if (!candidate || !site || !url) throw new BadRequestError(`Receipt ${id} does not need a signed-in proof`);
    return { ...candidate, site, printUrl: url };
  }

  return {
    pending: async (): Promise<PendingSite[]> => groupBySite(await deps.pending()),

    /**
     * Classifies the page. A page that shows the receipt keeps its PDF in the archive bucket. A page that does not
     * show it gets the fidelity `wrong_page`, without a PDF. Other results write no row, so the receipt stays pending.
     */
    result: async (page: PageResult): Promise<{ fidelity: Fidelity }> => {
      const candidate = await find(page.id);
      const classified = classify(
        { ok: true, status: page.status, finalUrl: page.finalUrl, pdf: new Uint8Array(), download: false, hasPasswordField: page.hasPasswordField, text: page.text },
        candidate,
      );
      if (!WRITTEN.has(classified)) return { fidelity: classified };

      const fidelity = classified === "merchant_page" ? "merchant_page" : "wrong_page";
      let pdfKey: string | null = null;
      if (fidelity === "merchant_page") {
        if (!page.pdf) throw new BadRequestError(`The page of ${candidate.id} shows the receipt, but the PDF is missing`);
        pdfKey = signedInPdfKey(candidate);
        await deps.putPdf(pdfKey, page.pdf);
      }
      await deps.write({
        id: candidate.id,
        messageId: candidate.messageId,
        site: candidate.site,
        fidelity,
        url: candidate.printUrl,
        finalUrl: page.finalUrl,
        httpStatus: page.status,
        pdfKey,
        checkedAt: deps.now(),
      });
      return { fidelity };
    },
  };
}

export type SignedInProofs = ReturnType<typeof createSignedInProofs>;
