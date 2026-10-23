import { describe, expect, it } from "vitest";
import { buildWhere, startOfDay, type SearchFilter } from "./where.ts";

const TZ = "America/New_York";
const none: SearchFilter = {
  from: [],
  to: [],
  after: null,
  before: null,
  labelIds: [],
  includeSpamTrash: false,
  hasAttachment: null,
};

describe("buildWhere", () => {
  it("always leaves out deleted messages, spam, and trash", () => {
    expect(buildWhere(none, TZ)).toBe("deleted = false AND NOT array_has_any(labels, ['SPAM', 'TRASH'])");
  });

  it("can include spam and trash", () => {
    expect(buildWhere({ ...none, includeSpamTrash: true }, TZ)).toBe("deleted = false");
  });

  it("builds every filter", () => {
    const filter: SearchFilter = {
      from: ["Amazon", "ebay"],
      to: ["bob"],
      after: "2025-01-01",
      before: "2026-01-01",
      labelIds: ["Label_1"],
      includeSpamTrash: false,
      hasAttachment: true,
    };

    expect(buildWhere(filter, TZ)).toBe(
      "deleted = false AND NOT array_has_any(labels, ['SPAM', 'TRASH'])" +
        " AND array_has_all(labels, ['Label_1'])" +
        " AND (contains(fromKey, 'amazon') OR contains(fromKey, 'ebay'))" +
        " AND (contains(toKey, 'bob'))" +
        " AND date >= timestamp '2025-01-01 05:00:00'" +
        " AND date < timestamp '2026-01-01 05:00:00'" +
        " AND hasAttachment = true",
    );
  });

  it("escapes single quotes in every value", () => {
    const where = buildWhere({ ...none, from: ["o'brien"], labelIds: ["x' OR 1=1 --"] }, TZ);

    expect(where).toContain("contains(fromKey, 'o''brien')");
    expect(where).toContain("array_has_all(labels, ['x'' OR 1=1 --'])");
  });

  it("ignores blank terms", () => {
    expect(buildWhere({ ...none, from: ["  "] }, TZ)).toBe(buildWhere(none, TZ));
  });
});

describe("startOfDay", () => {
  it.each<[string, string]>([
    ["2025-01-01", "2025-01-01T05:00:00.000Z"],
    ["2025-07-01", "2025-07-01T04:00:00.000Z"],
    ["2025-03-09", "2025-03-09T05:00:00.000Z"],
    ["2025-11-02", "2025-11-02T04:00:00.000Z"],
  ])("finds the UTC time of midnight on %s", (day, utc) => {
    expect(startOfDay(day, TZ).toISOString()).toBe(utc);
  });

  it("rejects a value that is not a date", () => {
    expect(() => startOfDay("next week", TZ)).toThrow("Not a date: next week");
  });
});
