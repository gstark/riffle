// Indexer Lambda entry point. EventBridge Scheduler starts it every minute. See infra/search-indexer.tf.

import { GetObjectCommand, NoSuchKey, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { SQSClient } from "@aws-sdk/client-sqs";
import { z } from "zod";
import { log, requireEnv } from "../shared/runtime.ts";
import { createTitanEmbed } from "./embed.ts";
import { indexBatch } from "./indexer.ts";
import { createSqsQueue, drainQueue, sendIds } from "./queue.ts";
import { createS3Source } from "./source.ts";
import { ensureIndexes, openOrCreateTable, optimize } from "./table.ts";

/** The Lambda timeout is 15 minutes. Stop taking new batches after 12. */
const RUN_MS = 12 * 60_000;
/** Maintenance only starts in a run that drained the queue quickly, so it has time to finish. */
const MAINTENANCE_START_MS = 2 * 60_000;
const OPTIMIZE_EVERY_MS = 24 * 60 * 60_000;
/** In the index bucket, outside the table directory. */
const MAINTENANCE_KEY = "maintenance.json";

const MaintenanceSchema = z.object({ optimizedAt: z.iso.datetime() });

async function lastOptimized(s3: S3Client, bucket: string): Promise<number> {
  try {
    const object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: MAINTENANCE_KEY }));
    const { optimizedAt } = MaintenanceSchema.parse(JSON.parse((await object.Body?.transformToString()) ?? "{}"));
    return Date.parse(optimizedAt);
  } catch (error) {
    if (error instanceof NoSuchKey) return 0;
    throw error;
  }
}

export async function handler(): Promise<void> {
  const started = Date.now();
  const s3 = new S3Client();
  const indexBucket = requireEnv("INDEX_BUCKET");
  const table = await openOrCreateTable(`s3://${indexBucket}`);
  const deps = {
    source: createS3Source(s3, requireEnv("ARCHIVE_BUCKET")),
    table,
    embed: createTitanEmbed(),
    concurrency: 16,
    log,
  };

  const sqs = new SQSClient();
  const receiptsQueueUrl = requireEnv("RECEIPTS_QUEUE_URL");
  const { drained } = await drainQueue({
    queue: createSqsQueue(sqs, requireEnv("QUEUE_URL")),
    handle: async (ids) => {
      const result = await indexBatch(ids, deps);
      // New messages go on to receipt extraction. If this send fails, the run fails and the alarm fires.
      // The rows are written already, so the next run does not send these IDs again: run enqueue-receipts.ts.
      await sendIds(sqs, receiptsQueueUrl, [...result.addedIds]);
      return result;
    },
    describe: (result) =>
      `Indexed: ${result.addedIds.size} added, ${result.updated} updated, ${result.failedIds.size} failed`,
    deadline: started + RUN_MS,
    now: Date.now,
    log,
  });
  if (!drained || Date.now() - started > MAINTENANCE_START_MS) return;
  if ((await table.countRows()) === 0) return;

  await ensureIndexes(table, log);
  if (Date.now() - (await lastOptimized(s3, indexBucket)) > OPTIMIZE_EVERY_MS) {
    log("Optimizing the table");
    await optimize(table);
    await s3.send(
      new PutObjectCommand({
        Bucket: indexBucket,
        Key: MAINTENANCE_KEY,
        Body: JSON.stringify({ optimizedAt: new Date().toISOString() }),
        ContentType: "application/json",
      }),
    );
  }
}
