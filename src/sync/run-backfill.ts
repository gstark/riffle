// Usage: ARCHIVE_BUCKET=... GMAIL_USER=... GOOGLE_SECRET_ID=... AWS_REGION=... node src/sync/run-backfill.ts

import { log } from "../shared/runtime.ts";
import { backfill } from "./backfill.ts";
import { connect } from "./connect.ts";

const result = await backfill({ ...(await connect()), concurrency: 10, requestsPerSecond: 40, log });

log(`Done: ${result.archived} archived, ${result.vanished} vanished, ${result.failed} failed`);
if (result.failed > 0) {
  log("Run the backfill again to retry the failed messages.");
  process.exitCode = 1;
}
