// Lists the messages of recent months. The raw/ keys hold the receive month, so no meta file is read.

import { paginateListObjectsV2, type S3Client } from "@aws-sdk/client-s3";
import { gmailIdFromRawKey, recentRawPrefixes } from "../shared/storage.ts";

/** IDs of the messages received in the last `months` UTC calendar months, newest month first. */
export async function listRecentIds(s3: S3Client, bucket: string, months: number, now = new Date()): Promise<string[]> {
  const ids: string[] = [];
  for (const prefix of recentRawPrefixes(now, months)) {
    for await (const page of paginateListObjectsV2({ client: s3 }, { Bucket: bucket, Prefix: prefix })) {
      for (const object of page.Contents ?? []) {
        const id = object.Key && gmailIdFromRawKey(object.Key);
        if (id) ids.push(id);
      }
    }
  }
  return ids;
}
