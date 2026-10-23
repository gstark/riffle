import { rawKey, type MessageMeta } from "../shared/storage.ts";
import type { Archive } from "./archive.ts";
import type { GmailReader, RawMessage } from "./gmail.ts";

/**
 * Fetches a message from Gmail and writes it to the archive.
 * Returns false when the message no longer exists in Gmail.
 */
export async function archiveMessage(gmail: GmailReader, archive: Archive, id: string): Promise<boolean> {
  const message = await gmail.getRawMessage(id);
  if (!message) return false;
  await archive.putMessage(Buffer.from(message.raw, "base64url"), toMeta(message));
  return true;
}

function toMeta(message: RawMessage): MessageMeta {
  const internalDate = new Date(Number(message.internalDate));
  return {
    id: message.id,
    threadId: message.threadId,
    labelIds: message.labelIds ?? [],
    internalDate: internalDate.toISOString(),
    historyId: message.historyId,
    sizeEstimate: message.sizeEstimate,
    rawKey: rawKey(message.id, internalDate),
    deletedAt: null,
    updatedAt: new Date().toISOString(),
  };
}
