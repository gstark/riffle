// Proofs Lambda entry point. EventBridge Scheduler starts it every minute. See infra/proofs.tf.
// The browser is an AgentCore Browser session (proof-browser.ts). It starts only when the queue has work.

import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { SQSClient } from "@aws-sdk/client-sqs";
import { createSqsQueue, drainQueue } from "../search/queue.ts";
import { createS3Source } from "../search/source.ts";
import { optimize } from "../search/table.ts";
import { log, requireEnv } from "../shared/runtime.ts";
import { openProofBrowser } from "./proof-browser.ts";
import { openOrCreateProofs } from "./proof-table.ts";
import { openOrCreateReceipts } from "./table.ts";
import { PROOFS_BATCH_IDS, processProofBatch } from "./proofs-worker.ts";

/** The Lambda timeout is 15 minutes. Stop taking new batches after 10: a slow batch can take about 4 minutes. */
const RUN_MS = 10 * 60_000;
/** AgentCore stops the browser session after this time. The Lambda timeout is 15 minutes. */
const SESSION_SECONDS = 15 * 60;
/** Emails checked at the same time. Each one opens its links one after the other. */
const CONCURRENCY = 4;
const MAX_LINKS = 3;

export async function handler(): Promise<void> {
  const started = Date.now();
  const indexUri = `s3://${requireEnv("INDEX_BUCKET")}`;
  const archiveBucket = requireEnv("ARCHIVE_BUCKET");
  const s3 = new S3Client();
  const proofs = await openOrCreateProofs(indexUri);
  const browser = openProofBrowser({
    region: requireEnv("AWS_REGION"),
    browserId: requireEnv("BROWSER_ID"),
    sessionSeconds: SESSION_SECONDS,
  });
  const deps = {
    source: createS3Source(s3, archiveBucket),
    receipts: await openOrCreateReceipts(indexUri),
    proofs,
    browser,
    putPdf: async (key: string, pdf: Uint8Array) => {
      await s3.send(
        new PutObjectCommand({
          Bucket: archiveBucket,
          Key: key,
          Body: pdf,
          ContentType: "application/pdf",
          StorageClass: "INTELLIGENT_TIERING",
        }),
      );
    },
    maxLinks: MAX_LINKS,
    concurrency: CONCURRENCY,
    now: () => new Date(),
    log,
  };

  let changes = 0;
  try {
    const { drained } = await drainQueue({
      queue: createSqsQueue(new SQSClient(), requireEnv("QUEUE_URL")),
      batchIds: PROOFS_BATCH_IDS,
      handle: async (ids) => {
        const result = await processProofBatch(ids, deps);
        changes += result.written + result.removed;
        return result;
      },
      describe: (result) =>
        `Proofs: ${result.written} rows written, ${result.removed} messages without receipts, ${result.failedIds.size} failed`,
      deadline: started + RUN_MS,
      now: Date.now,
      log,
    });
    if (drained && changes > 0) await optimize(proofs);
  } finally {
    await browser.close();
  }
}
