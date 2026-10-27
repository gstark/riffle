// Quoted phrases in the search text. A phrase such as "Claude Duet" must appear in the message with those
// words in that order. The full-text index lowercases every token, so the match ignores case.

/** Straight or curly double quotes. */
const QUOTE = `["“”]`;
const QUOTED = new RegExp(`${QUOTE}([^"“”]*)${QUOTE}`, "g");
const LONE_QUOTE = new RegExp(QUOTE, "g");

export interface SplitText {
  /** The quoted phrases, without their quotes. Empty quotes are left out. */
  phrases: string[];
  /** The text outside the quotes, with single spaces. */
  words: string;
}

export function splitPhrases(text: string): SplitText {
  const phrases: string[] = [];
  const rest = text.replace(QUOTED, (_, phrase: string) => {
    const clean = phrase.trim();
    if (clean !== "") phrases.push(clean);
    return " ";
  });
  // A quote without a partner is not a phrase. It goes away so the words stay clean.
  const words = rest.replace(LONE_QUOTE, " ").split(/\s+/).filter(Boolean).join(" ");
  return { phrases, words };
}

/** The phrase in straight quotes, ready to join back into search text. */
export const quote = (phrase: string) => `"${phrase}"`;

/** The phrases and words as one search text, phrases first. */
export const joinText = (phrases: string[], words: string) => [...phrases.map(quote), words].filter(Boolean).join(" ");
