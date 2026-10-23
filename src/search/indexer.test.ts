import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { MessageMeta } from "../shared/storage.ts";
import { meta } from "../sync/test-fakes.ts";
import { drainQueue, indexBatch, type IndexerDeps } from "./indexer.ts";
import type { Queue, QueueMessage } from "./queue.ts";
import { openOrCreateTable, readRows } from "./table.ts";
import { fakeEmbed, fakeSource, rawEmail } from "./test-fakes.ts";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "search-indexer-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

/** Every meta gets a raw message, except the IDs in `withoutRaw`. */
async function setup(metas: MessageMeta[], withoutRaw: string[] = []) {
  const raws = Object.fromEntries(
    metas.filter((m) => !withoutRaw.includes(m.id)).map((m) => [m.rawKey, rawEmail({ subject: `Subject ${m.id}` })]),
  );
  const { source, metaById } = fakeSource({ metas, raws });
  const embedded: string[] = [];
  const deps: IndexerDeps = {
    source,
    table: await openOrCreateTable(dir),
    embed: async (text) => {
      embedded.push(text);
      return fakeEmbed(text);
    },
    concurrency: 4,
    log: () => {},
  };
  return { deps, metaById, embedded };
}

describe("indexBatch", () => {
  it("adds new messages once, even when an ID repeats", async () => {
    const { deps, embedded } = await setup([meta("a"), meta("b")]);

    const result = await indexBatch(["a", "b", "a"], deps);

    expect(result).toEqual({ added: 2, updated: 0, failedIds: new Set() });
    expect(embedded).toHaveLength(2);
    expect((await readRows(deps.table, ["a"])).get("a")?.subject).toBe("Subject a");
  });

  it("updates labels without embedding the message again", async () => {
    const { deps, metaById, embedded } = await setup([meta("a")]);
    await indexBatch(["a"], deps);
    metaById.set("a", meta("a", ["STARRED"]));

    const result = await indexBatch(["a"], deps);

    expect(result).toEqual({ added: 0, updated: 1, failedIds: new Set() });
    expect(embedded).toHaveLength(1);
    expect((await readRows(deps.table, ["a"])).get("a")?.labels).toEqual(["STARRED"]);
  });

  it("marks a message that was deleted in Gmail", async () => {
    const { deps, metaById } = await setup([meta("a")]);
    await indexBatch(["a"], deps);
    metaById.set("a", { ...meta("a"), deletedAt: "2024-04-01T00:00:00.000Z" });

    await indexBatch(["a"], deps);

    expect((await readRows(deps.table, ["a"])).get("a")?.deleted).toBe(true);
  });

  it("does not add a deleted message that is not in the index", async () => {
    const { deps } = await setup([{ ...meta("a"), deletedAt: "2024-04-01T00:00:00.000Z" }]);

    const result = await indexBatch(["a"], deps);

    expect(result).toEqual({ added: 0, updated: 0, failedIds: new Set() });
    expect(await deps.table.countRows()).toBe(0);
  });

  it("does nothing when nothing changed", async () => {
    const { deps } = await setup([meta("a")]);
    await indexBatch(["a"], deps);

    expect(await indexBatch(["a"], deps)).toEqual({ added: 0, updated: 0, failedIds: new Set() });
  });

  it("reports a message that fails and still writes the others", async () => {
    const { deps } = await setup([meta("a"), meta("b")], ["b"]);

    const result = await indexBatch(["a", "b"], deps);

    expect(result).toEqual({ added: 1, updated: 0, failedIds: new Set(["b"]) });
    expect([...(await readRows(deps.table, ["a", "b"])).keys()]).toEqual(["a"]);
  });
});

function fakeQueue(batches: QueueMessage[][]) {
  const deleted: string[] = [];
  const queue: Queue = {
    receive: async () => batches.shift() ?? [],
    delete: async (handles) => {
      deleted.push(...handles);
    },
  };
  return { queue, deleted };
}

const done = (ids: string[], failed: string[] = []) => ({ added: ids.length, updated: 0, failedIds: new Set(failed) });

describe("drainQueue", () => {
  it("indexes batches until the queue is empty, and deletes only the messages that fully succeeded", async () => {
    const { queue, deleted } = fakeQueue([
      [
        { receiptHandle: "h1", ids: ["a", "b"] },
        { receiptHandle: "h2", ids: ["c"] },
      ],
      [{ receiptHandle: "h3", ids: ["d"] }],
    ]);
    const seen: string[][] = [];

    const result = await drainQueue({
      queue,
      index: async (ids) => {
        seen.push(ids);
        return done(ids, ids.includes("c") ? ["c"] : []);
      },
      deadline: Infinity,
      now: () => 0,
      log: () => {},
    });

    expect(result).toEqual({ drained: true });
    expect(seen).toEqual([["a", "b", "c"], ["d"]]);
    expect(deleted).toEqual(["h1", "h3"]);
  });

  it("stops at the deadline", async () => {
    let time = 0;
    const { queue } = fakeQueue([[{ receiptHandle: "h1", ids: ["a"] }], [{ receiptHandle: "h2", ids: ["b"] }]]);

    const result = await drainQueue({
      queue,
      index: async (ids) => {
        time += 10;
        return done(ids);
      },
      deadline: 5,
      now: () => time,
      log: () => {},
    });

    expect(result).toEqual({ drained: false });
  });
});
