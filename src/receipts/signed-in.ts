// Proofs that the Riffle app makes on the Mac, in a browser with your sign-in, for the receipts whose link needs a
// sign-in or blocks the AgentCore Browser. The search Lambda serves these routes. See
// docs/superpowers/specs/2026-10-29-signed-in-proofs-design.md.

import { BadRequestError } from "../search/request.ts";
import { classify, type Fidelity } from "./proof.ts";

/** Fidelities of `receipt_proofs` that the Riffle app can make better with a sign-in. */
export const PENDING_FIDELITIES: readonly Fidelity[] = ["login_required", "blocked"];
/** Fidelities that the signed-in result keeps. Other results leave the receipt pending. */
const KEPT: ReadonlySet<Fidelity> = new Set(["merchant_page", "unverified_page"]);

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
  pdfKey: string;
  checkedAt: Date;
};

/** What the Riffle app saw on the printed page. */
export interface PageResult {
  id: string;
  finalUrl: string;
  status: number | null;
  hasPasswordField: boolean;
  text: string;
}

export interface SignedInDeps {
  /** Receipts with a `login_required` or `blocked` proof and no signed-in row. */
  pending: () => Promise<Candidate[]>;
  /** The receipt with this ID when its proof is `login_required` or `blocked`, with or without a signed-in row. */
  candidate: (id: string) => Promise<Candidate | null>;
  /**
   * A presigned PUT URL for a PDF in the archive bucket. The archive bucket has Object Lock, so S3 needs a checksum:
   * the upload must send `sha256` (base64) in the x-amz-checksum-sha256 header.
   */
  presignPut: (key: string, sha256: string) => Promise<string>;
  pdfExists: (key: string) => Promise<boolean>;
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

/** The site of the session that the receipt needs, for example "amazon.com". Null when the receipt has no link. */
export function siteKey(candidate: Candidate): string | null {
  if (amazonOrderId(candidate)) return "amazon.com";
  const name = host(candidate.finalUrl) ?? host(candidate.url);
  return name ? name.split(".").slice(-2).join(".") : null;
}

/** The page that Riffle prints: the Amazon invoice of the order, or the receipt link. */
export function printUrl(candidate: Candidate): string | null {
  const orderId = amazonOrderId(candidate);
  if (orderId) return `https://www.amazon.com/gp/css/summary/print.html?orderID=${orderId}`;
  return candidate.url;
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

    upload: async (id: string, sha256: string): Promise<{ url: string; key: string }> => {
      const key = signedInPdfKey(await find(id));
      return { url: await deps.presignPut(key, sha256), key };
    },

    /** Classifies the page. Writes a row only for a page that Riffle keeps, and only when its PDF is in S3. */
    result: async (page: PageResult): Promise<{ fidelity: Fidelity }> => {
      const candidate = await find(page.id);
      const fidelity = classify(
        { ok: true, status: page.status, finalUrl: page.finalUrl, pdf: new Uint8Array(), download: false, hasPasswordField: page.hasPasswordField, text: page.text },
        candidate,
      );
      if (!KEPT.has(fidelity)) return { fidelity };

      const pdfKey = signedInPdfKey(candidate);
      if (!(await deps.pdfExists(pdfKey))) throw new BadRequestError(`Upload the PDF of receipt ${page.id} first`);
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
