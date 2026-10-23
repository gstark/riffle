import type { Archive } from "./archive.ts";
import type { GmailReader } from "./gmail.ts";
import { archiveMessage } from "./messages.ts";
import { rateLimiter, runPool } from "./pool.ts";

export interface SyncOptions {
  gmail: GmailReader;
  archive: Archive;
  concurrency: number;
  requestsPerSecond: number;
  log: (message: string) => void;
}

export interface SyncResult {
  archived: number;
  relabeled: number;
  deleted: number;
  failed: number;
}

type Change = "changed" | "deleted";

/**
 * Applies the Gmail changes since the saved history ID to the archive:
 * new messages are archived, label changes update meta, deletions set deletedAt.
 * The history ID only moves forward when every change succeeds, so a failed run is retried in full.
 */
export async function syncChanges({
  gmail,
  archive,
  concurrency,
  requestsPerSecond,
  log,
}: SyncOptions): Promise<SyncResult> {
  const state = await archive.getSyncState();
  if (!state?.backfillComplete) throw new Error("The backfill is not complete. Run it first.");

  // The last event for a message wins: a message that is added and then deleted is only deleted.
  const changes = new Map<string, Change>();
  let latestHistoryId = state.historyId;
  for await (const page of gmail.listHistory(state.historyId)) {
    for (const record of page.records) {
      const changed = [record.messagesAdded, record.labelsAdded, record.labelsRemoved].flatMap((m) => m ?? []);
      for (const { message } of changed) changes.set(message.id, "changed");
      for (const { message } of record.messagesDeleted ?? []) changes.set(message.id, "deleted");
    }
    latestHistoryId = page.historyId;
  }

  const result: SyncResult = { archived: 0, relabeled: 0, deleted: 0, failed: 0 };
  const limit = rateLimiter(requestsPerSecond);
  const now = new Date().toISOString();

  const markDeleted = async (id: string) => {
    const meta = await archive.getMeta(id);
    if (meta && !meta.deletedAt) {
      await archive.putMeta({ ...meta, deletedAt: now, updatedAt: now });
      result.deleted++;
    }
  };

  await runPool(changes, concurrency, async ([id, change]) => {
    try {
      if (change === "deleted") return await markDeleted(id);

      await limit();
      const meta = await archive.getMeta(id);
      if (!meta) {
        if (await archiveMessage(gmail, archive, id)) result.archived++;
        return;
      }

      const current = await gmail.getMessageLabels(id);
      if (!current) return await markDeleted(id);
      if (!sameLabels(meta.labelIds, current.labelIds)) {
        await archive.putMeta({ ...meta, ...current, updatedAt: now });
        result.relabeled++;
      }
    } catch (error) {
      result.failed++;
      log(`Failed ${id}: ${error instanceof Error ? error.message : String(error)}`);
    }
  });

  const labels = await gmail.listLabels();
  if (JSON.stringify(labels) !== JSON.stringify(await archive.getLabels())) {
    await archive.putLabels(labels);
  }

  if (result.failed === 0 && latestHistoryId !== state.historyId) {
    await archive.putSyncState({ ...state, historyId: latestHistoryId });
  }
  return result;
}

function sameLabels(a: string[], b: string[]): boolean {
  return a.length === b.length && a.toSorted().join() === b.toSorted().join();
}
