// Creates missing indexes and optimizes the table from the dev machine.
// Use it when index creation needs more memory or time than the indexer Lambda has.
// Disable the indexer schedule first: the table must have only one writer.
//
//   AWS_PROFILE=automation INDEX_BUCKET=... node src/search/maintain.ts

import { log, requireEnv } from "../shared/runtime.ts";
import { ensureIndexes, openOrCreateTable, optimize } from "./table.ts";

const table = await openOrCreateTable(`s3://${requireEnv("INDEX_BUCKET")}`);
await ensureIndexes(table, log);
log("Optimizing the table");
await optimize(table);
log(`Done. ${await table.countRows()} rows, indexes: ${(await table.listIndices()).map((i) => i.name).join(", ")}`);
