// Turns a natural-language search into search text and filters with Claude Opus 5.5 on Bedrock.
// If Claude fails, the search uses the plain text, so a search always returns results.

import { AnthropicBedrockMantle } from "@anthropic-ai/bedrock-sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";
import type { Label } from "../shared/storage.ts";
import type { SearchFilter } from "./where.ts";

export const MODEL = "anthropic.claude-opus-5-5";
// Mantle serves Opus 5.5 in us-east-1 only. In us-east-2 it answers 404 "model does not exist".
const CLAUDE_REGION = "us-east-1";
const TIMEOUT_MS = 10_000;

export type Sort = "relevance" | "newest" | "oldest";

/** Who decided the filters: Claude, nobody (Claude failed, plain text), or the request (exact filters). */
export type Source = "claude" | "plain" | "filters";

export function outputSchema(labelNames: string[]) {
  return z.object({
    text: z.string(),
    from: z.array(z.string()),
    to: z.array(z.string()),
    after: z.iso.date().nullable(),
    before: z.iso.date().nullable(),
    labels: z.array(z.enum(labelNames)),
    includeSpamTrash: z.boolean(),
    hasAttachment: z.boolean().nullable(),
    sort: z.enum(["relevance", "newest", "oldest"]),
  });
}

export type OutputSchema = ReturnType<typeof outputSchema>;
export type ModelOutput = z.infer<OutputSchema>;

export interface ParsedQuery extends SearchFilter {
  text: string;
  /** Label names, for display. `labelIds` has the same labels for the filter. */
  labels: string[];
  sort: Sort;
  source: Source;
}

/** Sends the query to Claude. Returns its structured output, or null when Claude gives none. */
export type ReadQuery = (request: { system: string; query: string; schema: OutputSchema }) => Promise<ModelOutput | null>;

export interface ParseOptions {
  read: ReadQuery;
  labels: Label[];
  now: Date;
  timeZone: string;
  log: (message: string) => void;
}

export function createClaudeReader(
  client = new AnthropicBedrockMantle({ awsRegion: CLAUDE_REGION }),
): ReadQuery {
  return async ({ system, query, schema }) => {
    const response = await client.messages.parse(
      {
        model: MODEL,
        max_tokens: 16_000,
        // Opus 5.5 always thinks. Low effort keeps the delay short for this small task.
        output_config: { effort: "low", format: zodOutputFormat(schema) },
        system,
        messages: [{ role: "user", content: query }],
      },
      { timeout: TIMEOUT_MS, maxRetries: 0 },
    );
    // A refusal or a cut-off answer has no usable output.
    return response.stop_reason === "end_turn" ? response.parsed_output : null;
  };
}

export function plainQuery(query: string): ParsedQuery {
  return {
    text: query,
    from: [],
    to: [],
    after: null,
    before: null,
    labels: [],
    labelIds: [],
    includeSpamTrash: false,
    hasAttachment: null,
    sort: "relevance",
    source: "plain",
  };
}

export function systemPrompt(labels: Label[], now: Date, timeZone: string): string {
  const today = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  const weekday = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "long" }).format(now);
  return `You turn a search of the user's Gmail archive into search text and filters.

Today is ${weekday}, ${today}. The user's time zone is ${timeZone}.

Fields:
- text: the topic words to match in the message. Remove the words that you turned into filters. Remove words such as "email", "emails", "message", "find", and "show". Use an empty string when no topic words are left.
- from: parts of sender names, email addresses, or domains, in lower case, such as "amazon" or "jane". Use the shortest part that identifies the sender. A person or company name with no word such as "to", "about", or "for" before it is the sender, in any position in the query. For a full name, use the family name only, because the sender can show as "Smith, John" or "jsmith@example.com".
- to: the same as from, for recipients. Use it only when the query says who received the message.
- after: the first day to include, as YYYY-MM-DD. Null when there is no start date.
- before: the first day to leave out, as YYYY-MM-DD. Null when there is no end date.
- labels: Gmail labels that the message must have. Use only names from the label list. Use a label only when the query names it clearly.
- includeSpamTrash: true only when the query asks for spam or trash.
- hasAttachment: true when the query asks for attachments or a file type, such as "pdf". False when it asks for messages without attachments. Otherwise null.
- sort: "newest" for "latest", "most recent", or "last". "oldest" for "first" or "earliest". Otherwise "relevance".

Date rules:
- "last year" is the previous calendar year. "this year" starts on January 1 of this year.
- "last month" is the previous calendar month.
- "last week" starts 7 days before today and includes today.
- "in 2023" means after 2023-01-01 and before 2024-01-01.
- "since March" starts on the most recent March 1 that is not in the future.
- "recent" and "recently" do not set a date.

Labels:
${labels.map((label) => `- ${label.name}`).join("\n")}

Examples. In these examples, today is Thursday, 2026-10-22.
- "invoices from amazon last year": text "invoices", from ["amazon"], after "2025-01-01", before "2026-01-01"
- "emails from mom last week": text "", from ["mom"], after "2026-10-15", before "2026-10-23"
- "flight confirmations to denver": text "flight confirmation denver"
- "latest message from github": text "", from ["github"], sort "newest"
- "pdfs from my accountant in 2024": text "accountant", hasAttachment true, after "2024-01-01", before "2025-01-01"
- "starred emails about the roof": text "roof", labels ["STARRED"]
- "what did I send to sarah about the wedding": text "wedding", to ["sarah"], labels ["SENT"]
- "spam about crypto": text "crypto", includeSpamTrash true
- "the first email from delta": text "", from ["delta"], sort "oldest"
- "2024 John Smith Thanksgiving": text "thanksgiving", from ["smith"], after "2024-01-01", before "2025-01-01"
- "chase statement march": text "statement", from ["chase"], after "2026-03-01", before "2026-04-01"
- "tax documents": text "tax documents"`;
}

/** Labels that a query can name. Spam and trash have their own field. */
export const searchableLabels = (labels: Label[]) => labels.filter((label) => label.id !== "SPAM" && label.id !== "TRASH");

export async function parseQuery(query: string, { read, labels, now, timeZone, log }: ParseOptions): Promise<ParsedQuery> {
  const choices = searchableLabels(labels);
  const idByName = new Map(choices.map((label) => [label.name, label.id]));
  try {
    const output = await read({
      system: systemPrompt(choices, now, timeZone),
      query,
      schema: outputSchema([...idByName.keys()]),
    });
    if (output) {
      return { ...output, labelIds: output.labels.flatMap((name) => idByName.get(name) ?? []), source: "claude" };
    }
    log("The query parser gave no output. Searching the plain text.");
  } catch (error) {
    log(`The query parser failed. Searching the plain text. ${error instanceof Error ? error.message : String(error)}`);
  }
  return plainQuery(query);
}
