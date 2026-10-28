import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { MessageMeta } from "../shared/storage.ts";
import { meta } from "../sync/test-fakes.ts";
import { indexBatch, type IndexerDeps } from "./indexer.ts";
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

    expect(result).toEqual({ addedIds: new Set(["a", "b"]), toggledIds: new Set(), updated: 0, failedIds: new Set() });
    expect(embedded).toHaveLength(2);
    expect((await readRows(deps.table, ["a"])).get("a")?.subject).toBe("Subject a");
  });

  it("updates labels without embedding the message again", async () => {
    const { deps, metaById, embedded } = await setup([meta("a")]);
    await indexBatch(["a"], deps);
    metaById.set("a", meta("a", ["STARRED"]));

    const result = await indexBatch(["a"], deps);

    expect(result).toEqual({ addedIds: new Set(), toggledIds: new Set(), updated: 1, failedIds: new Set() });
    expect(embedded).toHaveLength(1);
    expect((await readRows(deps.table, ["a"])).get("a")?.labels).toEqual(["STARRED"]);
  });

  it("marks a message that was deleted in Gmail", async () => {
    const { deps, metaById } = await setup([meta("a")]);
    await indexBatch(["a"], deps);
    metaById.set("a", { ...meta("a"), deletedAt: "2024-04-01T00:00:00.000Z" });

    const result = await indexBatch(["a"], deps);

    expect(result.toggledIds).toEqual(new Set(["a"]));
    expect((await readRows(deps.table, ["a"])).get("a")?.deleted).toBe(true);
  });

  it("does not add a deleted message that is not in the index", async () => {
    const { deps } = await setup([{ ...meta("a"), deletedAt: "2024-04-01T00:00:00.000Z" }]);

    const result = await indexBatch(["a"], deps);

    expect(result).toEqual({ addedIds: new Set(), toggledIds: new Set(), updated: 0, failedIds: new Set() });
    expect(await deps.table.countRows()).toBe(0);
  });

  it("does nothing when nothing changed", async () => {
    const { deps } = await setup([meta("a")]);
    await indexBatch(["a"], deps);

    expect(await indexBatch(["a"], deps)).toEqual({ addedIds: new Set(), toggledIds: new Set(), updated: 0, failedIds: new Set() });
  });

  it("reports a message that fails and still writes the others", async () => {
    const { deps } = await setup([meta("a"), meta("b")], ["b"]);

    const result = await indexBatch(["a", "b"], deps);

    expect(result).toEqual({ addedIds: new Set(["a"]), toggledIds: new Set(), updated: 0, failedIds: new Set(["b"]) });
    expect([...(await readRows(deps.table, ["a", "b"])).keys()]).toEqual(["a"]);
  });
});
