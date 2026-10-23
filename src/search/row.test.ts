import { describe, expect, it } from "vitest";
import { meta } from "../sync/test-fakes.ts";
import { buildRow, embeddingInput, MAX_EMBED_CHARS, SNIPPET_CHARS } from "./row.ts";

const fields = {
  from: "Jane <Jane@Example.com>",
  to: "Me <me@example.com>",
  subject: "Invoice",
  attachments: ["a.pdf", "b.png"],
  body: "Total due",
};

describe("buildRow", () => {
  it("builds a row from the metadata and the extracted fields", () => {
    expect(buildRow(meta("m1", ["INBOX", "Label_1"]), fields, [0.5])).toEqual({
      id: "m1",
      threadId: "t-m1",
      date: new Date("2024-03-09T00:00:00.000Z"),
      from: "Jane <Jane@Example.com>",
      fromKey: "jane <jane@example.com>",
      to: "Me <me@example.com>",
      toKey: "me <me@example.com>",
      subject: "Invoice",
      labels: ["INBOX", "Label_1"],
      attachments: "a.pdf b.png",
      hasAttachment: true,
      snippet: "Total due",
      text: "Invoice\na.pdf b.png\nTotal due",
      vector: [0.5],
      deleted: false,
    });
  });

  it("marks a message that was deleted in Gmail", () => {
    const row = buildRow({ ...meta("m1"), deletedAt: "2024-04-01T00:00:00.000Z" }, fields, [0.5]);

    expect(row.deleted).toBe(true);
  });

  it("limits the snippet", () => {
    const row = buildRow(meta("m1"), { ...fields, body: "x".repeat(1000) }, [0.5]);

    expect(row.snippet).toHaveLength(SNIPPET_CHARS);
  });
});

describe("embeddingInput", () => {
  it("starts with the sender and subject and fits the Titan limit", () => {
    const input = embeddingInput({ ...fields, body: "word ".repeat(5000) });

    expect(input.startsWith("From: Jane <Jane@Example.com>\nSubject: Invoice\nword")).toBe(true);
    expect(input).toHaveLength(MAX_EMBED_CHARS);
  });
});
