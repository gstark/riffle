// Read access to the archive bucket for the search code.

import { GetObjectCommand, NoSuchKey, S3Client } from "@aws-sdk/client-s3";
import {
  LABELS_KEY,
  LabelSchema,
  MessageMetaSchema,
  metaKey,
  type Label,
  type MessageMeta,
} from "../shared/storage.ts";

export interface MessageSource {
  getMeta(id: string): Promise<MessageMeta | null>;
  /** Raw RFC 822 bytes at the meta's `rawKey`. */
  getRaw(key: string): Promise<Uint8Array>;
  getLabels(): Promise<Label[]>;
}

export function createS3Source(s3: S3Client, bucket: string): MessageSource {
  const get = async (key: string) => {
    const object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    if (!object.Body) throw new Error(`${key} has no body`);
    return object.Body.transformToByteArray();
  };
  const getJson = async (key: string): Promise<unknown> => JSON.parse(new TextDecoder().decode(await get(key)));

  return {
    async getMeta(id) {
      try {
        return MessageMetaSchema.parse(await getJson(metaKey(id)));
      } catch (error) {
        if (error instanceof NoSuchKey) return null;
        throw error;
      }
    },
    getRaw: get,
    getLabels: async () => LabelSchema.array().parse(await getJson(LABELS_KEY)),
  };
}
