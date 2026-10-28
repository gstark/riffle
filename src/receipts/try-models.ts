// Compares the candidate receipt models on real mail and writes a report to .spike/ (git ignores it).
// It reads real messages and calls Bedrock, so run it only with the user's approval. It costs less than $0.20.
//
//   AWS_PROFILE=automation AWS_REGION=us-east-2 ARCHIVE_BUCKET=... node src/receipts/try-models.ts

import { mkdir, writeFile } from "node:fs/promises";
import { S3Client } from "@aws-sdk/client-s3";
import { createS3Source } from "../search/source.ts";
import { log, requireEnv } from "../shared/runtime.ts";
import { modelInput, type ExtractionOutput } from "./extract-receipt.ts";
import { passesFilter } from "./filter.ts";
import { createHaiku45Model, createHaiku55Model } from "./models.ts";
import { listRecentIds } from "./recent.ts";
import { readReceiptEmail } from "./text.ts";

const SAMPLE_SIZE = 50;
const MONTHS = 24;
/** Stop looking for samples after this many messages. */
const MAX_READ = 3_000;
const COMPARED = ["kind", "total", "currency", "orderId", "receiptUrl"] as const;

interface Sample {
  id: string;
  passed: boolean;
  from: string;
  subject: string;
  input: string;
}
type Result = { output: ExtractionOutput } | { error: string };

function shuffle<T>(items: T[]): T[] {
  const copy = [...items];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j] as T, copy[i] as T];
  }
  return copy;
}

const senderDomain = (from: string) => /@([^>\s]+)/.exec(from)?.[1]?.toLowerCase() ?? from;
const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));
const compared = (result: Result) =>
  "output" in result
    ? JSON.stringify(result.output.receipts.map((receipt) => COMPARED.map((field) => receipt[field])))
    : `error: ${result.error}`;
const cell = (value: unknown) => String(value ?? "").replaceAll("|", "\\|").replaceAll("\n", " ");

const s3 = new S3Client();
const bucket = requireEnv("ARCHIVE_BUCKET");
const source = createS3Source(s3, bucket);
const ids = shuffle(await listRecentIds(s3, bucket, MONTHS));
log(`Found ${ids.length} messages in the last ${MONTHS} months`);

// One passed sample per sender domain, so the sample covers many merchants.
const passed: Sample[] = [];
const rejected: Sample[] = [];
const senders = new Set<string>();
for (const id of ids.slice(0, MAX_READ)) {
  if (passed.length >= SAMPLE_SIZE && rejected.length >= SAMPLE_SIZE) break;
  try {
    const meta = await source.getMeta(id);
    if (!meta || meta.deletedAt !== null) continue;
    const email = await readReceiptEmail(await source.getRaw(meta.rawKey));
    const sample = { id, from: email.from, subject: email.subject, input: modelInput(email, meta) };
    if (passesFilter(email.subject, email.text)) {
      const sender = senderDomain(email.from);
      if (passed.length < SAMPLE_SIZE && !senders.has(sender)) {
        senders.add(sender);
        passed.push({ ...sample, passed: true });
      }
    } else if (rejected.length < SAMPLE_SIZE) {
      rejected.push({ ...sample, passed: false });
    }
  } catch (error) {
    log(`Skipped ${id}: ${errorText(error)}`);
  }
}
log(`Samples: ${passed.length} passed the filter, ${rejected.length} rejected`);

const models = [createHaiku55Model(), createHaiku45Model()];
const rows: { sample: Sample; results: Result[] }[] = [];
for (const sample of [...passed, ...rejected]) {
  const results = await Promise.all(
    models.map(async (model): Promise<Result> => {
      try {
        return { output: await model.extract(sample.input) };
      } catch (error) {
        return { error: errorText(error) };
      }
    }),
  );
  rows.push({ sample, results });
  log(`${rows.length}: ${sample.subject}`);
}

const header = ["id", "filter", "from", "subject", "agree", ...models.map((model) => model.id)];
const lines = rows.map(({ sample, results }) => {
  const agree = new Set(results.map(compared)).size === 1;
  return [sample.id, sample.passed ? "pass" : "reject", sample.from, sample.subject, agree ? "yes" : "NO", ...results.map(compared)]
    .map(cell)
    .join(" | ");
});
const summary = models.map((model, n) => {
  const results = rows.map((row) => row.results[n]);
  const errors = results.filter((result) => result && "error" in result).length;
  const missed = rows.filter((row) => {
    const result = row.results[n];
    return !row.sample.passed && result !== undefined && "output" in result && result.output.receipts.length > 0;
  }).length;
  return `- ${model.id}: ${errors} errors, ${missed} receipts in the rejected sample`;
});
const disagreements = lines.filter((line) => line.includes(" | NO | ")).length;

await mkdir(".spike", { recursive: true });
await writeFile(".spike/receipts-models.json", JSON.stringify(rows, null, 2));
await writeFile(
  ".spike/receipts-models.md",
  [
    "# Receipt model comparison",
    "",
    `Compared fields: ${COMPARED.join(", ")}. Disagreements: ${disagreements} of ${rows.length}.`,
    "",
    ...summary,
    "",
    `| ${header.join(" | ")} |`,
    `|${header.map(() => "---").join("|")}|`,
    ...lines.map((line) => `| ${line} |`),
    "",
  ].join("\n"),
);
log("Wrote .spike/receipts-models.md and .spike/receipts-models.json");
