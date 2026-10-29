// Selects the links of a receipt email that can go to a receipt page. Rules only, no model call.

import { htmlToText } from "../search/extract.ts";

export interface EmailLink {
  url: string;
  /** Visible text of the link, empty for an image link */
  text: string;
}

const ANCHOR = /<a\b[^>]*?\shref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))[^>]*>([\s\S]*?)<\/a>/gi;

/** Links that unsubscribe or change settings, anywhere in the link. */
const UNSUBSCRIBE = /unsubscribe|opt[-_ ]?out|preferences|manage[-_ ]?(your[-_ ])?(email|notification|subscription)s?/i;
/** Words for actions that change the account, in the link text or the URL path. "Confirmation" is not one of them. */
const ACTION = /\b(cancel|confirm|approve|accept|decline|verify|reset|delete|remove)\b/i;
/** Hosts and pages that cannot be a receipt. */
const NOT_RECEIPT =
  /privacy|terms|legal|facebook\.|twitter\.|x\.com\/|instagram\.|linkedin\.|youtube\.|tiktok\.|pinterest\.|apps\.apple\.com|itunes\.apple\.com|play\.google\.com/i;

function urlPath(url: string): string {
  try {
    const { host, pathname } = new URL(url);
    return host + pathname;
  } catch {
    return url;
  }
}

/** Links that must never be opened: they can change the account, or they cannot be a receipt. */
function neverOpen(url: string, text: string): boolean {
  const path = urlPath(url);
  return (
    UNSUBSCRIBE.test(url) || UNSUBSCRIBE.test(text) || ACTION.test(text) || ACTION.test(path) || NOT_RECEIPT.test(path)
  );
}

const RECEIPT_TEXT =
  /receipt|invoice|order (details|summary|status)|view (your )?(order|bill|statement|purchase)|download|pdf|billing/i;
const RECEIPT_URL = /receipt|invoice|\.pdf\b|billing|order/i;
/** Most links that the model chose are good candidates, but some are only a tracking redirect. */
const MODEL_SCORE = 3;
const TEXT_SCORE = 3;
const URL_SCORE = 2;

/** The http and https links of an HTML email, in document order, with the entities in the URL decoded. */
export function emailLinks(html: string): EmailLink[] {
  return [...html.matchAll(ANCHOR)].flatMap(([, double, single, bare, inner = ""]) => {
    const url = (double ?? single ?? bare ?? "").trim().replaceAll("&amp;", "&");
    return /^https?:\/\//i.test(url) ? [{ url, text: htmlToText(inner).replace(/\s+/g, " ").trim() }] : [];
  });
}

/**
 * The links to try, best first, at most `max`. A link must have a receipt word in its text or URL, or be a link
 * that the model chose. `modelUrls` can also be links that are only in the plain text.
 */
export function selectLinks(links: EmailLink[], modelUrls: string[], max: number): string[] {
  const scores = new Map<string, number>();
  const add = (url: string, score: number) => scores.set(url, Math.max(scores.get(url) ?? 0, score));
  for (const { url, text } of links) {
    if (neverOpen(url, text)) continue;
    add(url, (RECEIPT_TEXT.test(text) ? TEXT_SCORE : 0) + (RECEIPT_URL.test(url) ? URL_SCORE : 0));
  }
  for (const url of modelUrls) {
    if (/^https?:\/\//i.test(url) && !neverOpen(url, "")) add(url, (scores.get(url) ?? 0) + MODEL_SCORE);
  }
  return [...scores]
    .filter(([, score]) => score > 0)
    .toSorted((a, b) => b[1] - a[1])
    .slice(0, max)
    .map(([url]) => url);
}
