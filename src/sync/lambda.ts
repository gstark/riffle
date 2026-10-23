// Lambda entry point. EventBridge Scheduler invokes it every 5 minutes. See infra/lambda.tf.

import { log } from "../shared/runtime.ts";
import { connect } from "./connect.ts";
import { syncChanges, type SyncResult } from "./incremental.ts";

export async function handler(): Promise<SyncResult> {
  const result = await syncChanges({ ...(await connect()), concurrency: 5, requestsPerSecond: 40, log });

  log(
    `Sync: ${result.archived} archived, ${result.relabeled} relabeled, ` +
      `${result.deleted} deleted, ${result.failed} failed`,
  );
  // Throwing marks the invocation as an error, which the CloudWatch alarm counts.
  if (result.failed > 0) throw new Error(`${result.failed} changes failed. The next run retries them.`);
  return result;
}
