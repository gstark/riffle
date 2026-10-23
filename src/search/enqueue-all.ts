// Full build: sends the ID of every archived message to the index queue. The indexer Lambda does the rest.
//
//   AWS_PROFILE=automation ARCHIVE_BUCKET=... QUEUE_URL=... node src/search/enqueue-all.ts

import { S3Client } from "@aws-sdk/client-s3";
import { SQSClient } from "@aws-sdk/client-sqs";
import { log, requireEnv } from "../shared/runtime.ts";
import { createS3Archive } from "../sync/archive.ts";
import { sendIds } from "./queue.ts";

const ids = [...(await createS3Archive(new S3Client(), requireEnv("ARCHIVE_BUCKET")).listMessageIds())];
log(`Found ${ids.length} messages`);
await sendIds(new SQSClient(), requireEnv("QUEUE_URL"), ids);
log(`Queued ${ids.length} message IDs`);
