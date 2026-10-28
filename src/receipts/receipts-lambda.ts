// Receipts Lambda entry point. EventBridge Scheduler starts it every minute. See infra/receipts.tf.

import { S3Client } from "@aws-sdk/client-s3";
import { SQSClient } from "@aws-sdk/client-sqs";
import { createSqsQueue, drainQueue } from "../search/queue.ts";
import { createS3Source } from "../search/source.ts";
import { optimize } from "../search/table.ts";
import { log, requireEnv } from "../shared/runtime.ts";
import { createReceiptModel } from "./models.ts";
import { openOrCreateReceipts } from "./table.ts";
import { processBatch } from "./worker.ts";

/** The Lambda timeout is 15 minutes. Stop taking new batches after 12. */
const RUN_MS = 12 * 60_000;
/** Model calls at the same time. More can pass the Bedrock on-demand rate limits. */
const CONCURRENCY = 4;

export async function handler(): Promise<void> {
  const started = Date.now();
  const table = await openOrCreateReceipts(`s3://${requireEnv("INDEX_BUCKET")}`);
  const deps = {
    source: createS3Source(new S3Client(), requireEnv("ARCHIVE_BUCKET")),
    table,
    model: createReceiptModel(),
    concurrency: CONCURRENCY,
    now: () => new Date(),
    log,
  };

  let changes = 0;
  const { drained } = await drainQueue({
    queue: createSqsQueue(new SQSClient(), requireEnv("QUEUE_URL")),
    // Each batch writes its rows once at the end, so a small batch finishes well inside the Lambda timeout.
    batchIds: 200,
    handle: async (ids) => {
      const result = await processBatch(ids, deps);
      changes += result.written + result.removed;
      return result;
    },
    describe: (result) =>
      `Receipts: ${result.written} rows written, ${result.removed} removed, ${result.modelCalls} model calls, ${result.failedIds.size} failed`,
    deadline: started + RUN_MS,
    now: Date.now,
    log,
  });

  // Each batch adds a table version and a small file. Merge them when the queue is empty.
  if (drained && changes > 0) await optimize(table);
}
