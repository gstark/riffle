// Builds the index row for one message.

import type { MessageMeta } from "../shared/storage.ts";
import type { Extracted } from "./extract.ts";
import type { IndexRow } from "./schema.ts";

/** Titan v2 accepts a maximum of 8,192 tokens. 8,000 characters stays below it for normal text. */
export const MAX_EMBED_CHARS = 8_000;
/** Upper limit for the full-text column, so one very large message cannot fill the Lambda memory. */
export const MAX_TEXT_CHARS = 100_000;
export const SNIPPET_CHARS = 200;

/** The text that the vector represents: sender, subject, and the start of the body. */
export function embeddingInput(fields: Extracted): string {
  return `From: ${fields.from}\nSubject: ${fields.subject}\n${fields.body}`.slice(0, MAX_EMBED_CHARS);
}

export function buildRow(meta: MessageMeta, fields: Extracted, vector: number[]): IndexRow {
  const attachments = fields.attachments.join(" ");
  return {
    id: meta.id,
    threadId: meta.threadId,
    date: new Date(meta.internalDate),
    from: fields.from,
    fromKey: fields.from.toLowerCase(),
    to: fields.to,
    toKey: fields.to.toLowerCase(),
    subject: fields.subject,
    labels: meta.labelIds,
    attachments,
    hasAttachment: fields.attachments.length > 0,
    snippet: fields.body.slice(0, SNIPPET_CHARS),
    text: [fields.subject, attachments, fields.body]
      .filter((part) => part !== "")
      .join("\n")
      .slice(0, MAX_TEXT_CHARS),
    vector,
    deleted: meta.deletedAt !== null,
  };
}
