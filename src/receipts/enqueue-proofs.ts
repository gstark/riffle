// Proofs backfill: sends the IDs of messages with receipts but without proof rows at PROOFS_VERSION to the proofs queue.
//
//   AWS_PROFILE=automation AWS_REGION=us-east-2 INDEX_BUCKET=... PROOFS_QUEUE_URL=... [LIMIT=<messages>] \
//     node src/receipts/enqueue-proofs.ts

import { SQSClient } from "@aws-sdk/client-sqs";
import { sendIds } from "../search/queue.ts";
import { log, requireEnv } from "../shared/runtime.ts";
import { openOrCreateProofs, readCheckedMessages } from "./proof-table.ts";
import { PROOFS_BATCH_IDS } from "./proofs-worker.ts";
import { openOrCreateReceipts } from "./table.ts";

const indexUri = `s3://${requireEnv("INDEX_BUCKET")}`;
const limit = Number(process.env.LIMIT ?? Infinity);

const checked = await readCheckedMessages(await openOrCreateProofs(indexUri));
const rows: Record<string, unknown>[] = await (
  await openOrCreateReceipts(indexUri)
)
  .query()
  .where("kind != 'none'")
  .select(["messageId"])
  .toArray();
const ids = [...new Set(rows.map((row) => String(row.messageId)))].filter((id) => !checked.has(id));
// A random sample, so a small LIMIT covers many merchants.
const sample = ids
  .map((id) => ({ id, order: Math.random() }))
  .toSorted((a, b) => a.order - b.order)
  .slice(0, limit)
  .map(({ id }) => id);

log(`${ids.length} messages with receipts have no proofs`);
await sendIds(new SQSClient(), requireEnv("PROOFS_QUEUE_URL"), sample, PROOFS_BATCH_IDS);
log(`Queued ${sample.length} message IDs`);
