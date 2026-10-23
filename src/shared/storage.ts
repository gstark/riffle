// S3 layout of the archive bucket. See infra/s3.tf.

import { z } from "zod";

export const SYNC_STATE_KEY = "state/sync.json";
export const LABELS_KEY = "state/labels.json";

/** Contents of meta/<gmail-id>.json. */
export const MessageMetaSchema = z.object({
  id: z.string(),
  threadId: z.string(),
  labelIds: z.array(z.string()),
  /** Gmail receive time, ISO 8601. */
  internalDate: z.string(),
  historyId: z.string(),
  sizeEstimate: z.number(),
  rawKey: z.string(),
  /** Set when the message is deleted in Gmail. The raw object is kept. */
  deletedAt: z.string().nullable(),
  updatedAt: z.string(),
});
export type MessageMeta = z.infer<typeof MessageMetaSchema>;

/** Contents of state/sync.json. */
export const SyncStateSchema = z.object({
  /** Incremental sync starts from this Gmail history ID. */
  historyId: z.string(),
  backfillComplete: z.boolean(),
});
export type SyncState = z.infer<typeof SyncStateSchema>;

/** Contents of state/labels.json is an array of these. */
export const LabelSchema = z.object({
  id: z.string(),
  name: z.string(),
  type: z.string(),
});
export type Label = z.infer<typeof LabelSchema>;

/** Key of the original RFC 822 message. `internalDate` is Gmail's receive time. */
export function rawKey(gmailId: string, internalDate: Date): string {
  const yyyy = internalDate.getUTCFullYear().toString();
  const mm = (internalDate.getUTCMonth() + 1).toString().padStart(2, "0");
  return `raw/${yyyy}/${mm}/${gmailId}.eml`;
}

/** Key of the mutable metadata JSON (labels, thread id, deleted flag). */
export function metaKey(gmailId: string): string {
  return `meta/${gmailId}.json`;
}

/** Inverse of metaKey. Returns null for keys outside meta/. */
export function gmailIdFromMetaKey(key: string): string | null {
  const match = /^meta\/([^/]+)\.json$/.exec(key);
  return match?.[1] ?? null;
}
