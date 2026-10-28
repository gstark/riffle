// Prints the number of rows of each kind and the newest receipts.
//
//   AWS_PROFILE=automation AWS_REGION=us-east-2 INDEX_BUCKET=... node src/receipts/show-receipts.ts [count]

import { requireEnv } from "../shared/runtime.ts";
import { openOrCreateReceipts } from "./table.ts";

const count = Number(process.argv[2] ?? "20");
const table = await openOrCreateReceipts(`s3://${requireEnv("INDEX_BUCKET")}`);

const kinds: Record<string, unknown>[] = await table.query().select(["kind", "decidedBy"]).toArray();
const counts = new Map<string, number>();
for (const row of kinds) {
  const key = `${String(row.kind)} (${row.decidedBy === "filter" ? "filter" : "model"})`;
  counts.set(key, (counts.get(key) ?? 0) + 1);
}
console.table(Object.fromEntries([...counts].toSorted()));

const receipts: Record<string, unknown>[] = await table
  .query()
  .where("kind != 'none'")
  .select(["date", "kind", "merchant", "total", "currency", "orderId", "paymentMethod", "receiptUrl"])
  .toArray();
console.table(
  receipts
    .toSorted((a, b) => Number(b.date) - Number(a.date))
    .slice(0, count)
    .map((row) => ({ ...row, date: new Date(Number(row.date)).toISOString().slice(0, 10) })),
);
