import { describe, expect, it } from "vitest";
import { backfill } from "./backfill.ts";
import { INBOX, fakeArchive, fakeGmail, message, meta } from "./test-fakes.ts";

const options = { concurrency: 2, requestsPerSecond: 1000, log: () => {} };

// Two pages, plus an ID that is deleted before it is fetched.
const gmail = (failIds: string[] = [], historyId = "100") =>
  fakeGmail({
    messages: [message("a"), message("b")],
    listPages: [["a"], ["b", "vanished"]],
    historyId,
    failIds,
  });

describe("backfill", () => {
  it("archives raw messages and metadata, and marks the backfill complete", async () => {
    const { archive, raw, meta: metas, saved } = fakeArchive();

    const result = await backfill({ ...options, gmail: gmail(), archive });

    expect(result).toEqual({ archived: 2, vanished: 1, failed: 0 });
    expect(raw.get("raw/2024/03/a.eml")).toBe("Subject: a\r\n\r\nbody");
    expect(metas.get("a")).toMatchObject({
      id: "a",
      threadId: "t-a",
      labelIds: ["INBOX"],
      internalDate: "2024-03-09T00:00:00.000Z",
      rawKey: "raw/2024/03/a.eml",
      deletedAt: null,
    });
    expect(saved.labels).toEqual([INBOX]);
    expect(saved.state).toEqual({ historyId: "100", backfillComplete: true });
  });

  it("skips messages that are already archived", async () => {
    const { archive, raw } = fakeArchive({ metas: [meta("a")] });

    const result = await backfill({ ...options, gmail: gmail(), archive });

    expect(result.archived).toBe(1);
    expect([...raw.keys()]).toEqual(["raw/2024/03/b.eml"]);
  });

  it("keeps the history ID of the first run when it resumes", async () => {
    const { archive, saved } = fakeArchive({ state: { historyId: "42", backfillComplete: false } });

    await backfill({ ...options, gmail: gmail([], "999"), archive });

    expect(saved.state).toEqual({ historyId: "42", backfillComplete: true });
  });

  it("counts failures and leaves the backfill incomplete", async () => {
    const { archive, saved } = fakeArchive();

    const result = await backfill({ ...options, gmail: gmail(["b"]), archive });

    expect(result).toEqual({ archived: 1, vanished: 1, failed: 1 });
    expect(saved.state).toEqual({ historyId: "100", backfillComplete: false });
  });
});
