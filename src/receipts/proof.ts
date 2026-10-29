// Proof of purchase: what the receipt link of a receipt row gives, and how much it proves.

import { currencyDigits } from "./row.ts";

/** The best proof of a receipt, best first. Each receipt also has a PDF of the email itself. */
export const FIDELITIES = [
  /** The email has a PDF attachment, for example an invoice. */
  "attached_pdf",
  /** The link gave a PDF file. */
  "merchant_pdf",
  /** The link gave a page that shows the total or the order ID. It is rendered to PDF. */
  "merchant_page",
  /** The link gave a page without the total or the order ID, for example a help page. It is rendered to PDF. */
  "unverified_page",
  /** The link goes to a sign-in page. */
  "login_required",
  /** The site refused a browser without a person: status 403, 429, or 503, or a CAPTCHA. Amazon gives 503 for its robot check. */
  "blocked",
  /** Other HTTP errors, expired links, and timeouts. */
  "link_failed",
  /** Only in `signed_in_proofs`: the page loaded with a sign-in, but its PDF does not show the charge. No PDF is kept. */
  "wrong_page",
  /** The email has no link that can go to a receipt. */
  "no_link",
] as const;
export type Fidelity = (typeof FIDELITIES)[number];

/** Link fidelities that come with a PDF. */
export const WITH_PDF: ReadonlySet<Fidelity> = new Set(["merchant_pdf", "merchant_page", "unverified_page"]);
/** Fidelities that prove the receipt. Then no more links are opened. */
export const PROVES: ReadonlySet<Fidelity> = new Set(["attached_pdf", "merchant_pdf", "merchant_page"]);

/** The better of two fidelities. */
export const better = (a: Fidelity, b: Fidelity): Fidelity => (FIDELITIES.indexOf(a) <= FIDELITIES.indexOf(b) ? a : b);

/** The receipt data that a page must show. Amounts are in minor units. */
export interface ProofTarget {
  total: number | null;
  currency: string | null;
  orderId: string | null;
}

/** What a browser visit to a receipt link gave. */
export type Visit =
  | { ok: false; error: string }
  | {
      ok: true;
      /** HTTP status of the last page, null for a download */
      status: number | null;
      finalUrl: string;
      /** A PDF file: a download, or a page rendered to PDF */
      pdf: Uint8Array;
      /** True when the link gave a PDF file, not a page */
      download: boolean;
      hasPasswordField: boolean;
      /** Visible text of the page, empty for a download */
      text: string;
    };

const LOGIN_URL =
  /sign[-_]?in|log[-_]?in|signon|\bauth\.|\/auth\b|\/sso\b|accounts\.google\.|idmsa\.apple\.|appleid\.apple\./i;
const BLOCKED_TEXT = /captcha|are you a robot|verify you are (a )?human|access denied|unusual traffic/i;
const EXPIRED_TEXT = /link (has )?expired|link is no longer (valid|available)|expired link/i;

function isLoginUrl(url: string): boolean {
  try {
    const { host, pathname } = new URL(url);
    return LOGIN_URL.test(host + pathname);
  } catch {
    return false;
  }
}

/** Symbols for a whole amount without cents, for example "$65". */
const SYMBOLS: Record<string, string> = { USD: "$", CAD: "$", AUD: "$", EUR: "€", GBP: "£" };

/** Puts `separator` between groups of three digits. */
const group = (whole: string, separator: string): string => whole.replace(/\B(?=(\d{3})+(?!\d))/g, separator);

/**
 * The ways a page can write the amount: "1234.56", "1,234.56", "1234,56", "1.234,56", "1 234,56", and "$1,234" for an
 * amount without cents. ReceiptScan.swift in the Riffle app has the same rules.
 */
export function amountTexts(minor: number, currency: string | null): string[] {
  const digits = currencyDigits(currency);
  const [whole = "", fraction] = (minor / 10 ** digits).toFixed(digits).split(".");
  const join = (text: string, point: string) => (fraction === undefined ? text : `${text}${point}${fraction}`);
  const texts = [
    join(whole, "."),
    join(group(whole, ","), "."),
    join(whole, ","),
    join(group(whole, "."), ","),
    join(group(whole, " "), ","),
  ];
  const symbol = SYMBOLS[currency ?? ""];
  if (symbol && fraction !== undefined && /^0+$/.test(fraction)) texts.push(`${symbol}${group(whole, ",")}`);
  return [...new Set(texts)];
}

const escape = (text: string): string => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * A pattern for an amount that also finds it with a space between its parts. A page can put the parts in different
 * elements: `<div>$44</div><span>.12</span>` has the text "$44\n.12".
 */
const amountPattern = (amount: string): string => (amount.match(/\d+|[^\d\s]/g) ?? []).map(escape).join(" ?");

/**
 * True when the text shows the total or the order ID of the receipt. An amount must not be part of a larger number:
 * "13.90" is not in "113.90" or "13.905". Each run of white space counts as one space.
 */
export function showsReceipt(text: string, target: ProofTarget): boolean {
  const flat = text.replace(/\s+/g, " ");
  const amounts = target.total === null ? [] : amountTexts(target.total, target.currency);
  const orderIds = (target.orderId ?? "").split(/,\s*/).filter((id) => id.length >= 4);
  return (
    amounts.some((amount) => new RegExp(`(?<![\\d.,])${amountPattern(amount)}(?!\\d| ?[.,] ?\\d)`).test(flat)) ||
    orderIds.some((id) => flat.includes(id))
  );
}

/** The fidelity of a visit to the receipt link of `target`. */
export function classify(visit: Visit, target: ProofTarget): Fidelity {
  if (!visit.ok) return "link_failed";
  if (visit.download) return "merchant_pdf";
  if (visit.status === 401 || visit.hasPasswordField || isLoginUrl(visit.finalUrl)) return "login_required";
  if ([403, 429, 503].includes(visit.status ?? 0) || BLOCKED_TEXT.test(visit.text)) return "blocked";
  if ((visit.status !== null && visit.status >= 400) || EXPIRED_TEXT.test(visit.text)) return "link_failed";
  return showsReceipt(visit.text, target) ? "merchant_page" : "unverified_page";
}
