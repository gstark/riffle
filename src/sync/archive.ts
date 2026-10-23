import {
  GetObjectCommand,
  NoSuchKey,
  PutObjectCommand,
  S3Client,
  paginateListObjectsV2,
} from "@aws-sdk/client-s3";
import type { z } from "zod";
import {
  LABELS_KEY,
  LabelSchema,
  MessageMetaSchema,
  SYNC_STATE_KEY,
  SyncStateSchema,
  gmailIdFromMetaKey,
  metaKey,
  type Label,
  type MessageMeta,
  type SyncState,
} from "../shared/storage.ts";

export interface Archive {
  /** IDs of all messages that have a meta object. */
  listMessageIds(): Promise<Set<string>>;
  /** Writes the raw message first, then its meta. A meta object means the raw object exists. */
  putMessage(raw: Buffer, meta: MessageMeta): Promise<void>;
  getMeta(id: string): Promise<MessageMeta | null>;
  putMeta(meta: MessageMeta): Promise<void>;
  getSyncState(): Promise<SyncState | null>;
  putSyncState(state: SyncState): Promise<void>;
  getLabels(): Promise<Label[] | null>;
  putLabels(labels: Label[]): Promise<void>;
}

export function createS3Archive(s3: S3Client, bucket: string): Archive {
  // Objects are written directly to Intelligent-Tiering to avoid lifecycle transition charges.
  const put = (key: string, body: Buffer | string, contentType: string) =>
    s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: body,
        ContentType: contentType,
        StorageClass: "INTELLIGENT_TIERING",
      }),
    );

  const putJson = (key: string, value: unknown) =>
    put(key, JSON.stringify(value, null, 2), "application/json");

  const getJson = async <T>(key: string, schema: z.ZodType<T>): Promise<T | null> => {
    try {
      const object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
      const body = await object.Body?.transformToString();
      if (body === undefined) throw new Error(`${key} has no body`);
      return schema.parse(JSON.parse(body));
    } catch (error) {
      if (error instanceof NoSuchKey) return null;
      throw error;
    }
  };

  return {
    async listMessageIds() {
      const ids = new Set<string>();
      for await (const page of paginateListObjectsV2({ client: s3 }, { Bucket: bucket, Prefix: "meta/" })) {
        for (const object of page.Contents ?? []) {
          const id = object.Key && gmailIdFromMetaKey(object.Key);
          if (id) ids.add(id);
        }
      }
      return ids;
    },

    async putMessage(raw, meta) {
      await put(meta.rawKey, raw, "message/rfc822");
      await putJson(metaKey(meta.id), meta);
    },

    getMeta: (id) => getJson(metaKey(id), MessageMetaSchema),
    putMeta: async (meta) => {
      await putJson(metaKey(meta.id), meta);
    },

    getSyncState: () => getJson(SYNC_STATE_KEY, SyncStateSchema),
    putSyncState: async (state) => {
      await putJson(SYNC_STATE_KEY, state);
    },

    getLabels: () => getJson(LABELS_KEY, LabelSchema.array()),
    putLabels: async (labels) => {
      await putJson(LABELS_KEY, labels);
    },
  };
}
