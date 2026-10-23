// Sends sample queries to the real query parser (Claude Opus 5.5 on Bedrock) and prints what it reads.
// Use it to tune the prompt in parse-query.ts. Each query costs about $0.01.
//
//   AWS_PROFILE=automation ARCHIVE_BUCKET=... node src/search/try-parser.ts ["query"...]

import { S3Client } from "@aws-sdk/client-s3";
import { log, requireEnv } from "../shared/runtime.ts";
import { createClaudeReader, parseQuery } from "./parse-query.ts";
import { createS3Source } from "./source.ts";

const SAMPLES = [
  "invoices from amazon last year",
  "emails from mom last week",
  "flight confirmations to denver",
  "latest message from github",
  "pdfs from my accountant in 2024",
  "starred emails about the roof",
  "what did I send to sarah about the wedding",
  "tax documents",
  "receipts since march",
  "the first email from delta",
  "insurance renewal",
  "messages with attachments from the school this year",
  "spam about crypto",
  "anything from apple about my order",
  "photos from dad",
  "doctor appointment reminders",
  "unread newsletters",
  "emails I sent last month",
  "zoom links for the board meeting",
  "password reset",
];

const queries = process.argv.length > 2 ? process.argv.slice(2) : SAMPLES;
const labels = await createS3Source(new S3Client(), requireEnv("ARCHIVE_BUCKET")).getLabels();
const read = createClaudeReader();

for (const query of queries) {
  const started = performance.now();
  const parsed = await parseQuery(query, { read, labels, now: new Date(), timeZone: "America/New_York", log });
  console.log(`\n"${query}"  ${Math.round(performance.now() - started)} ms`);
  console.log(`  ${JSON.stringify(parsed)}`);
}
