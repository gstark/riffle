import type { Archive } from "./archive.ts";
import type { GmailReader } from "./gmail.ts";
import { archiveMessage } from "./messages.ts";
import { rateLimiter, runPool } from "./pool.ts";

export interface BackfillOptions {
  gmail: GmailReader;
  archive: Archive;
  concurrency: number;
  requestsPerSecond: number;
  log: (message: string) => void;
}

export interface BackfillResult {
  archived: number;
  /** Listed by Gmail but deleted or moved to spam before we could fetch them. */
  vanished: number;
  failed: number;
}

/**
 * Copies every Gmail message that is not yet in the archive. Safe to stop and run again.
 * The Gmail history ID is recorded before the first listing, so incremental sync
 * also picks up changes made while the backfill runs.
 */
export async function backfill({
  gmail,
  archive,
  concurrency,
  requestsPerSecond,
  log,
}: BackfillOptions): Promise<BackfillResult> {
  let state = await archive.getSyncState();
  if (!state) {
    state = { historyId: await gmail.getHistoryId(), backfillComplete: false };
    await archive.putSyncState(state);
  }

  await archive.putLabels(await gmail.listLabels());

  const archivedIds = await archive.listMessageIds();
  const pending: string[] = [];
  for await (const page of gmail.listMessageIds()) {
    pending.push(...page.filter((id) => !archivedIds.has(id)));
  }
  log(`${archivedIds.size} messages already archived, ${pending.length} to fetch`);

  const result: BackfillResult = { archived: 0, vanished: 0, failed: 0 };
  const limit = rateLimiter(requestsPerSecond);
  const started = Date.now();

  await runPool(pending, concurrency, async (id) => {
    try {
      await limit();
      if (await archiveMessage(gmail, archive, id)) {
        result.archived++;
      } else {
        result.vanished++;
      }
    } catch (error) {
      result.failed++;
      log(`Failed ${id}: ${error instanceof Error ? error.message : String(error)}`);
    }

    const done = result.archived + result.vanished + result.failed;
    if (done % 1000 === 0) {
      const perSecond = done / ((Date.now() - started) / 1000);
      const minutesLeft = (pending.length - done) / perSecond / 60;
      log(`${done}/${pending.length} (${perSecond.toFixed(1)}/s, ~${minutesLeft.toFixed(0)} min left)`);
    }
  });

  if (result.failed === 0 && !state.backfillComplete) {
    await archive.putSyncState({ ...state, backfillComplete: true });
  }
  return result;
}

