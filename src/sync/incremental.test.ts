import { describe, expect, it } from "vitest";
import type { HistoryRecord } from "./gmail.ts";
import { syncChanges } from "./incremental.ts";
import { INBOX, fakeArchive, fakeGmail, message, meta } from "./test-fakes.ts";

const options = { concurrency: 2, requestsPerSecond: 1000, log: () => {} };
const synced = { historyId: "10", backfillComplete: true };

const ref = (id: string) => ({ message: { id } });
const history = (...records: HistoryRecord[]) => [{ records, historyId: "20" }];

describe("syncChanges", () => {
  it("refuses to run before the backfill is complete", async () => {
    const { archive } = fakeArchive({ state: { historyId: "10", backfillComplete: false } });

    await expect(syncChanges({ ...options, gmail: fakeGmail(), archive })).rejects.toThrow(
      "backfill is not complete",
    );
  });

  it("archives new messages and advances the history ID", async () => {
    const { archive, raw, saved } = fakeArchive({ state: synced, labels: [INBOX] });
    const gmail = fakeGmail({ messages: [message("new")], history: history({ messagesAdded: [ref("new")] }) });

    const result = await syncChanges({ ...options, gmail, archive });

    expect(result).toEqual({ archived: 1, relabeled: 0, deleted: 0, failed: 0 });
    expect(raw.has("raw/2024/03/new.eml")).toBe(true);
    expect(saved.state).toEqual({ historyId: "20", backfillComplete: true });
  });

  it("updates meta when labels change, and skips it when they do not", async () => {
    const { archive, meta: metas, saved } = fakeArchive({
      state: synced,
      metas: [meta("a", ["INBOX", "UNREAD"]), meta("b", ["INBOX"])],
    });
    const gmail = fakeGmail({
      messages: [message("a", ["INBOX"]), message("b", ["INBOX"])],
      history: history({ labelsRemoved: [ref("a")] }, { labelsAdded: [ref("b")] }),
    });

    const result = await syncChanges({ ...options, gmail, archive });

    expect(result.relabeled).toBe(1);
    expect(metas.get("a")).toMatchObject({ labelIds: ["INBOX"], historyId: "500" });
    expect(saved.metaWrites).toBe(1);
  });

  it("marks deleted messages and keeps them in the archive", async () => {
    const { archive, meta: metas } = fakeArchive({ state: synced, metas: [meta("gone")] });
    const gmail = fakeGmail({ history: history({ messagesDeleted: [ref("gone")] }) });

    const result = await syncChanges({ ...options, gmail, archive });

    expect(result.deleted).toBe(1);
    expect(metas.get("gone")?.deletedAt).toEqual(expect.any(String));
  });

  it("treats a label change on a message that no longer exists as a deletion", async () => {
    const { archive, meta: metas } = fakeArchive({ state: synced, metas: [meta("gone")] });
    const gmail = fakeGmail({ history: history({ labelsAdded: [ref("gone")] }) });

    const result = await syncChanges({ ...options, gmail, archive });

    expect(result.deleted).toBe(1);
    expect(metas.get("gone")?.deletedAt).not.toBeNull();
  });

  it("ignores a message that is added and then deleted before it is archived", async () => {
    const { archive, raw } = fakeArchive({ state: synced });
    const gmail = fakeGmail({ history: history({ messagesAdded: [ref("x")] }, { messagesDeleted: [ref("x")] }) });

    const result = await syncChanges({ ...options, gmail, archive });

    expect(result).toEqual({ archived: 0, relabeled: 0, deleted: 0, failed: 0 });
    expect(raw.size).toBe(0);
  });

  it("does not advance the history ID when a change fails", async () => {
    const { archive, saved } = fakeArchive({ state: synced });
    const gmail = fakeGmail({ history: history({ messagesAdded: [ref("bad")] }), failIds: ["bad"] });

    const result = await syncChanges({ ...options, gmail, archive });

    expect(result.failed).toBe(1);
    expect(saved.state).toEqual(synced);
  });

  it("writes labels only when they change", async () => {
    const unchanged = fakeArchive({ state: synced, labels: [INBOX] });
    await syncChanges({ ...options, gmail: fakeGmail(), archive: unchanged.archive });
    expect(unchanged.saved.labelWrites).toBe(0);

    const work = { id: "Label_1", name: "Work", type: "user" };
    const changed = fakeArchive({ state: synced, labels: [INBOX] });
    await syncChanges({ ...options, gmail: fakeGmail({ labels: [INBOX, work] }), archive: changed.archive });
    expect(changed.saved.labels).toEqual([INBOX, work]);
  });
});
