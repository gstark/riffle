import { describe, expect, it } from "vitest";
import { gmailIdFromMetaKey, metaKey, rawKey } from "./storage.ts";

describe("rawKey", () => {
  it("partitions by UTC year and zero-padded month", () => {
    expect(rawKey("18c2f0a1b2c3d4e5", new Date("2024-03-09T12:00:00Z"))).toBe(
      "raw/2024/03/18c2f0a1b2c3d4e5.eml",
    );
  });

  it("uses UTC, not local time, at a month boundary", () => {
    expect(rawKey("abc", new Date("2023-12-31T23:30:00-05:00"))).toBe("raw/2024/01/abc.eml");
  });
});

describe("metaKey", () => {
  it("puts metadata under meta/", () => {
    expect(metaKey("abc")).toBe("meta/abc.json");
  });

  it("round-trips through gmailIdFromMetaKey", () => {
    expect(gmailIdFromMetaKey(metaKey("abc"))).toBe("abc");
  });
});

describe("gmailIdFromMetaKey", () => {
  it.each(["raw/2024/01/abc.eml", "meta/abc.txt", "meta/x/abc.json"])("rejects %s", (key: string) => {
    expect(gmailIdFromMetaKey(key)).toBeNull();
  });
});
