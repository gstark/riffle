// One time: sets deletedAt on archived spam. The archive no longer keeps spam, and Gmail deletes spam after 30 days,
// so only recent spam is left. The search index gives the candidates. The meta object decides.
// Each meta write starts the indexer, which marks the row deleted and removes the receipt row.
//
//   AWS_PROFILE=automation AWS_REGION=us-east-2 ARCHIVE_BUCKET=... INDEX_BUCKET=... node src/sync/mark-spam-deleted.ts

import { S3Client } from "@aws-sdk/client-s3";
import { openOrCreateTable } from "../search/table.ts";
import { log, requireEnv } from "../shared/runtime.ts";
import { createS3Archive } from "./archive.ts";
import { isSpam } from "./messages.ts";
import { runPool } from "./pool.ts";

const table = await openOrCreateTable(`s3://${requireEnv("INDEX_BUCKET")}`);
const rows: Record<string, unknown>[] = await table
  .query()
  .where("array_has_any(labels, ['SPAM']) AND NOT deleted")
  .select(["id"])
  .toArray();
log(`Found ${rows.length} spam messages in the index`);

const archive = createS3Archive(new S3Client(), requireEnv("ARCHIVE_BUCKET"));
const now = new Date().toISOString();
let marked = 0;
await runPool(
  rows.map((row) => String(row.id)),
  16,
  async (id) => {
    const meta = await archive.getMeta(id);
    if (!meta || meta.deletedAt !== null || !isSpam(meta.labelIds)) return;
    await archive.putMeta({ ...meta, deletedAt: now, updatedAt: now });
    marked++;
  },
);
log(`Marked ${marked} messages as deleted`);
