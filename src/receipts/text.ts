// Message text for the receipts model. Unlike the search text, it keeps link URLs,
// because the receipt link is one of the fields to extract.

import PostalMime from "postal-mime";
import { extractMessage, htmlToText } from "../search/extract.ts";

export interface ReceiptEmail {
  /** "Name <address>" */
  from: string;
  subject: string;
  /** Body text. HTML links are written as "link text [URL]". */
  text: string;
}

const ANCHOR = /<a\b[^>]*?\shref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))[^>]*>([\s\S]*?)<\/a>/gi;
const NUMERIC_ENTITY = /&#(?:x([0-9a-f]+)|(\d+));/gi;
const CURRENCY_ENTITIES: Record<string, string> = { "&euro;": "€", "&pound;": "£", "&yen;": "¥", "&cent;": "¢" };

/** htmlToText leaves these entities as they are, and the filter needs the currency symbols. */
function decodeCurrencyEntities(text: string): string {
  return text
    .replace(NUMERIC_ENTITY, (match, hex: string | undefined, dec: string | undefined) => {
      const code = hex === undefined ? Number(dec) : Number.parseInt(hex, 16);
      return code <= 0x10ffff ? String.fromCodePoint(code) : match;
    })
    .replace(/&(?:euro|pound|yen|cent);/gi, (name) => CURRENCY_ENTITIES[name.toLowerCase()] ?? name);
}

/** htmlToText, but each http or https link keeps its URL in brackets after the link text. */
export function htmlToTextWithLinks(html: string): string {
  return decodeCurrencyEntities(
    htmlToText(
      html.replace(ANCHOR, (_match, double?: string, single?: string, bare?: string, inner = "") => {
        const url = (double ?? single ?? bare ?? "").trim();
        return /^https?:\/\//i.test(url) ? `${inner} [${url}]` : inner;
      }),
    ),
  );
}

export async function readReceiptEmail(raw: Uint8Array): Promise<ReceiptEmail> {
  const [fields, email] = await Promise.all([extractMessage(raw), PostalMime.parse(raw)]);
  const html = email.html?.trim() ?? "";
  return { from: fields.from, subject: fields.subject, text: html ? htmlToTextWithLinks(html) : fields.body };
}
