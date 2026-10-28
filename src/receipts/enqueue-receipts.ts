// Receipts backfill: sends the IDs of the messages of the last MONTHS months (default 24) to the receipts queue.
// The receipts Lambda skips messages that already have a row, so the script can run again.
//
//   AWS_PROFILE=automation AWS_REGION=us-east-2 ARCHIVE_BUCKET=... RECEIPTS_QUEUE_URL=... [MONTHS=24] \
//     node src/receipts/enqueue-receipts.ts

import { S3Client } from "@aws-sdk/client-s3";
import { SQSClient } from "@aws-sdk/client-sqs";
import { sendIds } from "../search/queue.ts";
import { log, requireEnv } from "../shared/runtime.ts";
import { listRecentIds } from "./recent.ts";

const months = Number(process.env.MONTHS ?? "24");
if (!Number.isInteger(months) || months < 1) throw new Error("MONTHS must be a whole number of 1 or more");

const ids = await listRecentIds(new S3Client(), requireEnv("ARCHIVE_BUCKET"), months);
log(`Found ${ids.length} messages in the last ${months} months`);
await sendIds(new SQSClient(), requireEnv("RECEIPTS_QUEUE_URL"), ids);
log(`Queued ${ids.length} message IDs`);
