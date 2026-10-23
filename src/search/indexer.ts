// Keeps the search index in step with the archive.

import type * as lancedb from "@lancedb/lancedb";
import type { MessageMeta } from "../shared/storage.ts";
import { runPool } from "../sync/pool.ts";
import type { Embed } from "./embed.ts";
import { EMPTY_MESSAGE, extractMessage } from "./extract.ts";
import type { Queue } from "./queue.ts";
import { buildRow, embeddingInput } from "./row.ts";
import type { IndexRow } from "./schema.ts";
import type { MessageSource } from "./source.ts";
import { readRows, upsertRows } from "./table.ts";

export interface IndexerDeps {
  source: MessageSource;
  table: lancedb.Table;
  embed: Embed;
  concurrency: number;
  log: (message: string) => void;
}

export interface BatchResult {
  added: number;
  updated: number;
  /** IDs to try again later. */
  failedIds: Set<string>;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

function sameLabels(a: string[], b: string[]): boolean {
  return a.length === b.length && a.toSorted().join() === b.toSorted().join();
}

async function newRow(meta: MessageMeta, { source, embed, log }: IndexerDeps): Promise<IndexRow> {
  const raw = await source.getRaw(meta.rawKey);
  const fields = await extractMessage(raw).catch((error: unknown) => {
    log(`Cannot parse ${meta.id}, indexing it without a body: ${errorText(error)}`);
    return EMPTY_MESSAGE;
  });
  return buildRow(meta, fields, await embed(embeddingInput(fields)));
}

/**
 * Brings the rows for these IDs up to date with their meta objects, in one table write.
 * New messages are embedded. Label changes and deletions update the existing row only.
 */
export async function indexBatch(ids: string[], deps: IndexerDeps): Promise<BatchResult> {
  const unique = [...new Set(ids)];
  const existing = await readRows(deps.table, unique);
  const changed: IndexRow[] = [];
  const result: BatchResult = { added: 0, updated: 0, failedIds: new Set() };

  await runPool(unique, deps.concurrency, async (id) => {
    try {
      const meta = await deps.source.getMeta(id);
      if (!meta) return;
      const deleted = meta.deletedAt !== null;
      const row = existing.get(id);

      if (!row) {
        if (deleted) return;
        changed.push(await newRow(meta, deps));
        result.added++;
      } else if (row.deleted !== deleted || !sameLabels(row.labels, meta.labelIds)) {
        changed.push({ ...row, labels: meta.labelIds, deleted });
        result.updated++;
      }
    } catch (error) {
      result.failedIds.add(id);
      deps.log(`Failed ${id}: ${errorText(error)}`);
    }
  });

  await upsertRows(deps.table, changed);
  return result;
}

/** IDs per table write. */
const BATCH_IDS = 500;

export interface DrainOptions {
  queue: Queue;
  index: (ids: string[]) => Promise<BatchResult>;
  /** Stop receiving after this time, in epoch milliseconds. */
  deadline: number;
  now: () => number;
  log: (message: string) => void;
}

/**
 * Indexes queue batches until the queue is empty or the deadline passes.
 * A queue message is deleted only when all of its IDs succeeded. The others come back after the visibility timeout.
 */
export async function drainQueue({ queue, index, deadline, now, log }: DrainOptions): Promise<{ drained: boolean }> {
  while (now() < deadline) {
    const messages = await queue.receive(BATCH_IDS);
    if (messages.length === 0) return { drained: true };

    const result = await index(messages.flatMap((message) => message.ids));
    const finished = messages.filter((message) => message.ids.every((id) => !result.failedIds.has(id)));
    await queue.delete(finished.map((message) => message.receiptHandle));
    log(
      `Indexed: ${result.added} added, ${result.updated} updated, ${result.failedIds.size} failed ` +
        `(${finished.length} of ${messages.length} queue messages done)`,
    );
  }
  return { drained: false };
}
