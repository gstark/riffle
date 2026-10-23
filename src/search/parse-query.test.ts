import { describe, expect, it } from "vitest";
import type { Label } from "../shared/storage.ts";
import { parseQuery, plainQuery, type ModelOutput, type ParseOptions, type ReadQuery } from "./parse-query.ts";

const labels: Label[] = [
  { id: "INBOX", name: "INBOX", type: "system" },
  { id: "SPAM", name: "SPAM", type: "system" },
  { id: "Label_7", name: "Receipts", type: "user" },
];

const options = (read: ReadQuery): ParseOptions => ({
  read,
  labels,
  // 22:00 on 2026-10-22 in New York.
  now: new Date("2026-10-23T02:00:00Z"),
  timeZone: "America/New_York",
  log: () => {},
});

const output: ModelOutput = {
  text: "invoices",
  from: ["amazon"],
  to: [],
  after: "2025-01-01",
  before: "2026-01-01",
  labels: ["Receipts"],
  includeSpamTrash: false,
  hasAttachment: null,
  sort: "relevance",
};

describe("parseQuery", () => {
  it("returns Claude's reading, with label IDs for the filter", async () => {
    const parsed = await parseQuery("receipts from amazon last year", options(async () => output));

    expect(parsed).toEqual({ ...output, labelIds: ["Label_7"], source: "claude" });
  });

  it("sends the date, the time zone, and every label except spam and trash", async () => {
    let request: Parameters<ReadQuery>[0] | undefined;
    await parseQuery(
      "x",
      options(async (r) => {
        request = r;
        return output;
      }),
    );

    expect(request?.query).toBe("x");
    expect(request?.system).toContain("Today is Thursday, 2026-10-22.");
    expect(request?.system).toContain("America/New_York");
    expect(request?.system).toContain("- Receipts");
    expect(request?.system).not.toContain("- SPAM");
    expect(request?.schema.safeParse({ ...output, labels: ["SPAM"] }).success).toBe(false);
    expect(request?.schema.safeParse(output).success).toBe(true);
  });

  it("searches the plain text when Claude fails", async () => {
    const parsed = await parseQuery(
      "tax letter",
      options(async () => {
        throw new Error("timeout");
      }),
    );

    expect(parsed).toEqual(plainQuery("tax letter"));
  });

  it("searches the plain text when Claude gives no output", async () => {
    expect(await parseQuery("tax letter", options(async () => null))).toEqual(plainQuery("tax letter"));
  });
});
