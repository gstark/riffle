import { describe, expect, it } from "vitest";
import { joinText, splitPhrases } from "./phrase.ts";

describe("splitPhrases", () => {
  it("takes each quoted phrase out of the text", () => {
    expect(splitPhrases('"Claude Duet" waitlist "off the"')).toEqual({ phrases: ["Claude Duet", "off the"], words: "waitlist" });
  });

  it("accepts curly quotes, which macOS types", () => {
    expect(splitPhrases("“Claude Duet” from anthropic")).toEqual({ phrases: ["Claude Duet"], words: "from anthropic" });
  });

  it("leaves out empty quotes and a lone quote", () => {
    expect(splitPhrases('"" tax "  " letter " 2024')).toEqual({ phrases: [], words: "tax letter 2024" });
  });

  it("returns the text as words when there are no quotes", () => {
    expect(splitPhrases("  tax   letter ")).toEqual({ phrases: [], words: "tax letter" });
  });
});

describe("joinText", () => {
  it("puts the phrases in quotes before the words", () => {
    expect(joinText(["Claude Duet"], "waitlist")).toBe('"Claude Duet" waitlist');
    expect(joinText(["Claude Duet"], "")).toBe('"Claude Duet"');
    expect(joinText([], "")).toBe("");
  });
});
