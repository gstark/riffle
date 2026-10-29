// Runs the proof pass on a random sample of receipt emails on this machine and prints the results.
// It writes nothing: the PDFs stay in memory. It uses the AgentCore browser of the proofs Lambda.
//
//   AWS_PROFILE=automation AWS_REGION=us-east-2 INDEX_BUCKET=... ARCHIVE_BUCKET=... BROWSER_ID=... \
//     node src/receipts/try-proofs.ts [count]

import { S3Client } from "@aws-sdk/client-s3";
import { createS3Source } from "../search/source.ts";
import { requireEnv } from "../shared/runtime.ts";
import { runPool } from "../sync/pool.ts";
import { FIDELITIES } from "./proof.ts";
import { openProofBrowser } from "./proof-browser.ts";
import { checkMessage } from "./proof-pass.ts";
import { readProofEmail } from "./proof-email.ts";
import type { ProofAttempt, ProofDocument, ProofRow } from "./proof-table.ts";
import { readProofReceipts } from "./proofs-worker.ts";
import { openOrCreateReceipts } from "./table.ts";

const count = Number(process.argv[2] ?? "40");
const receipts = await openOrCreateReceipts(`s3://${requireEnv("INDEX_BUCKET")}`);
const source = createS3Source(new S3Client(), requireEnv("ARCHIVE_BUCKET"));

const all: Record<string, unknown>[] = await receipts.query().where("kind != 'none'").select(["messageId"]).toArray();
const ids = [...new Set(all.map((row) => String(row.messageId)))]
  .map((id) => ({ id, order: Math.random() }))
  .toSorted((a, b) => a.order - b.order)
  .slice(0, count)
  .map(({ id }) => id);
const byMessage = await readProofReceipts(receipts, ids);
const merchants = new Map(
  (
    (await receipts
      .query()
      .where(
        `id IN (${[...byMessage.values()]
          .flat()
          .map((r) => `'${r.id}'`)
          .join(", ")})`,
      )
      .select(["id", "merchant", "kind"])
      .toArray()) as Record<string, unknown>[]
  ).map((row) => [String(row.id), `${String(row.merchant)} (${String(row.kind)})`]),
);

const browser = openProofBrowser({
  region: requireEnv("AWS_REGION"),
  browserId: requireEnv("BROWSER_ID"),
  sessionSeconds: 60 * 60,
});
const results: ProofRow[] = [];
const started = Date.now();
try {
  const deps = { browser, putPdf: async () => {}, maxLinks: 3, now: () => new Date() };
  await runPool(ids, 4, async (id) => {
    const meta = await source.getMeta(id);
    const own = byMessage.get(id) ?? [];
    if (!meta || own.length === 0) return;
    const t = Date.now();
    const rows = await checkMessage(id, await readProofEmail(await source.getRaw(meta.rawKey)), own, deps).catch(
      (error: unknown) => {
        console.log(`FAILED ${id}: ${String(error)}`);
        return [];
      },
    );
    results.push(...rows);
    for (const row of rows) {
      const attempts = JSON.parse(row.attempts) as ProofAttempt[];
      const documents = JSON.parse(row.documents) as ProofDocument[];
      const tried = attempts.map((a) => `${a.fidelity}:${a.status ?? "-"} ${new URL(a.finalUrl ?? a.url).host}`);
      console.log(
        [
          row.fidelity.padEnd(15),
          (merchants.get(row.id) ?? "?").slice(0, 40).padEnd(40),
          `${Date.now() - t}ms`.padStart(7),
          `pdfs=${documents.length}`,
          tried.join(" | "),
        ].join("  "),
      );
    }
  });
} finally {
  await browser.close();
}

const counts = new Map(FIDELITIES.map((f) => [f, 0]));
for (const row of results) counts.set(row.fidelity, (counts.get(row.fidelity) ?? 0) + 1);
console.log(`\n${ids.length} emails, ${results.length} receipts, ${Math.round((Date.now() - started) / 1000)} s`);
console.table(Object.fromEntries(counts));
