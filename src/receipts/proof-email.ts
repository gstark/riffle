// The parts of a receipt email that the proofs Lambda needs: a printable page, the links, and the PDF attachments.

import PostalMime, { type Address } from "postal-mime";
import { emailLinks, type EmailLink } from "./links.ts";

export interface ProofEmail {
  /** HTML of the email with a From, To, Date, and Subject header. Inline images are data URLs. */
  page: string;
  links: EmailLink[];
  pdfs: { filename: string; content: Uint8Array }[];
}

const escapeHtml = (text: string) =>
  text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

const addressText = (addresses: Address[] = []) =>
  addresses
    .flatMap((address) => ("group" in address && address.group ? address.group : [address]))
    .map(({ name, address }) => (name ? `${name} <${address ?? ""}>` : (address ?? "")))
    .join(", ");

const bytes = (content: ArrayBuffer | Uint8Array | string) =>
  typeof content === "string" ? new TextEncoder().encode(content) : new Uint8Array(content);

export async function readProofEmail(raw: Uint8Array): Promise<ProofEmail> {
  const email = await PostalMime.parse(raw);
  const header = [
    ["From", addressText(email.from ? [email.from] : [])],
    ["To", addressText(email.to)],
    ["Date", email.date ?? ""],
    ["Subject", email.subject ?? ""],
  ]
    .map(([name, value]) => `<div><b>${name}:</b> ${escapeHtml(value ?? "")}</div>`)
    .join("");

  // Inline images ("cid:" links) are attachments. A data URL lets the page show them without the message.
  const inline = new Map(
    email.attachments.flatMap((a) =>
      a.contentId
        ? [
            [
              a.contentId.replace(/^<|>$/g, ""),
              `data:${a.mimeType};base64,${Buffer.from(bytes(a.content)).toString("base64")}`,
            ],
          ]
        : [],
    ),
  );
  const html = email.html?.trim()
    ? email.html.replace(/cid:([^"'\s)>]+)/gi, (match, id: string) => inline.get(id) ?? match)
    : `<pre style="white-space: pre-wrap; font-family: sans-serif">${escapeHtml(email.text ?? "")}</pre>`;

  return {
    page: `<div style="font: 13px sans-serif; border-bottom: 1px solid #999; padding: 8px; margin-bottom: 8px">${header}</div>${html}`,
    links: email.html ? emailLinks(email.html) : [],
    pdfs: email.attachments
      .filter((a) => a.mimeType === "application/pdf" || /\.pdf$/i.test(a.filename ?? ""))
      .map((a) => ({ filename: a.filename ?? "attachment.pdf", content: bytes(a.content) })),
  };
}
