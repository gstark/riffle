// Reads the fields that the search index stores from a raw RFC 822 message.

import PostalMime from "postal-mime";

export interface Extracted {
  /** "Name <address>" */
  from: string;
  /** To and Cc, as "Name <address>, ..." */
  to: string;
  subject: string;
  /** Filenames of real attachments. Inline parts, such as signature images, are not included. */
  attachments: string[];
  /** Body text with whitespace collapsed. */
  body: string;
}

/** Fields for a message that the parser cannot read. */
export const EMPTY_MESSAGE: Extracted = { from: "", to: "", subject: "", attachments: [], body: "" };

interface Address {
  name: string;
  address?: string;
  group?: { name: string; address: string }[];
}

function formatAddress(address: Address): string[] {
  if (address.group) return address.group.flatMap(formatAddress);
  if (!address.address) return address.name ? [address.name] : [];
  return [address.name ? `${address.name} <${address.address}>` : address.address];
}

const formatAddresses = (list: Address[]) => list.flatMap(formatAddress).join(", ");

const collapse = (text: string) => text.replace(/\s+/g, " ").trim();

export function htmlToText(html: string): string {
  return collapse(
    html
      .replace(/<(style|script)\b[\s\S]*?<\/\1>/gi, " ")
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/gi, " ")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/&quot;/gi, '"')
      .replace(/&#39;/gi, "'")
      .replace(/&amp;/gi, "&"),
  );
}

export async function extractMessage(raw: Uint8Array): Promise<Extracted> {
  const email = await PostalMime.parse(raw);
  const text = email.text?.trim() ? collapse(email.text) : "";
  return {
    from: email.from ? formatAddresses([email.from]) : "",
    to: formatAddresses([...(email.to ?? []), ...(email.cc ?? [])]),
    subject: email.subject ?? "",
    attachments: email.attachments
      .filter((attachment) => attachment.disposition !== "inline")
      .flatMap((attachment) => (attachment.filename ? [attachment.filename] : [])),
    body: text || htmlToText(email.html ?? ""),
  };
}
