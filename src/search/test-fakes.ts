// Test helpers for the search code.

import type { Label, MessageMeta } from "../shared/storage.ts";
import { DIMENSIONS } from "./schema.ts";
import type { MessageSource } from "./source.ts";

interface EmailParts {
  from?: string;
  to?: string;
  cc?: string;
  subject?: string;
  html?: string;
  text?: string;
  /** Filename of a PDF attachment. */
  attachment?: string;
}

/** Builds a multipart RFC 822 message. The body is "Hi there" when neither text nor html is given. */
export function rawEmail({
  from = "Jane Doe <jane@example.com>",
  to = "me@example.com",
  cc,
  subject = "Hello",
  html,
  text = html === undefined ? "Hi there" : undefined,
  attachment,
}: EmailParts = {}): Uint8Array {
  const headers = [`From: ${from}`, `To: ${to}`, ...(cc ? [`Cc: ${cc}`] : []), `Subject: ${subject}`, "MIME-Version: 1.0"];
  const parts: string[][] = [
    ...(text === undefined ? [] : [["Content-Type: text/plain; charset=utf-8", "", text]]),
    ...(html === undefined ? [] : [["Content-Type: text/html; charset=utf-8", "", html]]),
    ...(attachment
      ? [
          [
            "Content-Type: application/pdf",
            `Content-Disposition: attachment; filename="${attachment}"`,
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0xLjQK",
          ],
        ]
      : []),
  ];
  const lines = [
    ...headers,
    'Content-Type: multipart/mixed; boundary="b1"',
    "",
    ...parts.flatMap((part) => ["--b1", ...part]),
    "--b1--",
  ];
  return new TextEncoder().encode(lines.join("\r\n"));
}

/** Bag-of-words vector: texts that share words are close. Normalized like Titan v2 output. */
export async function fakeEmbed(text: string): Promise<number[]> {
  const vector = new Array<number>(DIMENSIONS).fill(0);
  for (const word of text.toLowerCase().match(/[a-z0-9]+/g) ?? []) {
    let slot = 0;
    for (const char of word) slot = (slot * 31 + char.charCodeAt(0)) % DIMENSIONS;
    vector[slot] = (vector[slot] ?? 0) + 1;
  }
  const length = Math.hypot(...vector) || 1;
  return vector.map((value) => value / length);
}

/** A vector with 1 at `slot`. Float32 stores it exactly, so tests can compare it after a round trip. */
export function unitVector(slot = 0): number[] {
  return Array.from({ length: DIMENSIONS }, (_, i) => (i === slot ? 1 : 0));
}

interface FakeSourceOptions {
  metas?: MessageMeta[];
  /** Raw messages by raw key. getRaw throws for a key that is not here. */
  raws?: Record<string, Uint8Array>;
  labels?: Label[];
}

export function fakeSource({ metas = [], raws = {}, labels = [] }: FakeSourceOptions = {}) {
  const metaById = new Map(metas.map((m) => [m.id, m]));
  const source: MessageSource = {
    getMeta: async (id) => metaById.get(id) ?? null,
    getRaw: async (key) => {
      const raw = raws[key];
      if (!raw) throw new Error(`No object at ${key}`);
      return raw;
    },
    getLabels: async () => labels,
  };
  return { source, metaById };
}
