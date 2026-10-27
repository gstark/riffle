// One search request: read the query (or take exact filters), embed the topic, search, and build the response.

import type * as lancedb from "@lancedb/lancedb";
import type { Label } from "../shared/storage.ts";
import type { Embed } from "./embed.ts";
import { parseQuery, plainQuery, type ParsedQuery, type ReadQuery, type Sort, type Source } from "./parse-query.ts";
import { joinText, splitPhrases } from "./phrase.ts";
import { exactQuery, type SearchInput } from "./request.ts";
import { searchTable } from "./search.ts";
import { buildWhere } from "./where.ts";

export interface SearchDeps {
  table: lancedb.Table;
  reranker: lancedb.rerankers.Reranker;
  embed: Embed;
  read: ReadQuery;
  getLabels: () => Promise<Label[]>;
  /** Gmail address, for the account in Gmail links. */
  gmailUser: string;
  timeZone: string;
  now: () => Date;
  log: (message: string) => void;
}

export interface SearchResult {
  id: string;
  threadId: string;
  /** ISO 8601 */
  date: string;
  from: string;
  subject: string;
  snippet: string;
  /** Label names. */
  labels: string[];
  hasAttachment: boolean;
  gmailUrl: string;
}

export interface SearchResponse {
  /** The filters that the search used. */
  query: {
    text: string;
    from: string[];
    to: string[];
    after: string | null;
    before: string | null;
    labels: string[];
    includeSpamTrash: boolean;
    hasAttachment: boolean | null;
    sort: Sort;
    source: Source;
  };
  results: SearchResult[];
  timings: { parseMs: number; embedMs: number; searchMs: number };
}

export const gmailUrl = (user: string, threadId: string) =>
  `https://mail.google.com/mail/?authuser=${encodeURIComponent(user)}#all/${threadId}`;

export interface LabelListItem {
  name: string;
  type: string;
}

/** The labels for GET /labels, sorted by name. */
export const labelList = (labels: Label[]): LabelListItem[] =>
  labels.map(({ name, type }) => ({ name, type })).sort((a, b) => a.name.localeCompare(b.name));

export function createSearch(deps: SearchDeps): (input: SearchInput, limit: number) => Promise<SearchResponse> {
  /**
   * Claude reads only the words outside the quotes. The quoted phrases go back into the text as written,
   * so the response and a later exact-filter request carry them. With nothing outside the quotes,
   * there is nothing to read, and the request itself has set the filters.
   */
  const readQuery = async (q: string, labels: Label[]): Promise<ParsedQuery> => {
    const { phrases, words } = splitPhrases(q);
    if (phrases.length === 0) {
      return parseQuery(q, { read: deps.read, labels, now: deps.now(), timeZone: deps.timeZone, log: deps.log });
    }
    const read = words
      ? await parseQuery(words, { read: deps.read, labels, now: deps.now(), timeZone: deps.timeZone, log: deps.log })
      : { ...plainQuery(""), source: "filters" as const };
    return { ...read, text: joinText(phrases, read.text) };
  };

  return async (input, limit) => {
    const labels = await deps.getLabels();
    const nameById = new Map(labels.map((label) => [label.id, label.name]));

    let started = performance.now();
    const read = "q" in input ? await readQuery(input.q, labels) : exactQuery(input.filters, labels);
    // With no topic, nothing ranks the messages, so the newest come first.
    const query = read.text === "" && read.sort === "relevance" ? { ...read, sort: "newest" as const } : read;
    const parseMs = Math.round(performance.now() - started);

    started = performance.now();
    // A quoted phrase searches the full-text index alone, so it needs no embedding.
    const vector = query.text && splitPhrases(query.text).phrases.length === 0 ? await deps.embed(query.text) : null;
    const embedMs = Math.round(performance.now() - started);

    started = performance.now();
    const hits = await searchTable(
      deps.table,
      { text: query.text, vector, where: buildWhere(query, deps.timeZone), sort: query.sort, limit },
      deps.reranker,
    );
    const searchMs = Math.round(performance.now() - started);

    // Timings and counts only. Search text and email content must not go to the logs.
    deps.log(`Search: ${hits.length} results, source ${query.source}, parse ${parseMs} ms, embed ${embedMs} ms, search ${searchMs} ms`);

    return {
      query: {
        text: query.text,
        from: query.from,
        to: query.to,
        after: query.after,
        before: query.before,
        labels: query.labels,
        includeSpamTrash: query.includeSpamTrash,
        hasAttachment: query.hasAttachment,
        sort: query.sort,
        source: query.source,
      },
      results: hits.map((hit) => ({
        ...hit,
        date: hit.date.toISOString(),
        labels: hit.labels.flatMap((id) => nameById.get(id) ?? []),
        gmailUrl: gmailUrl(deps.gmailUser, hit.threadId),
      })),
      timings: { parseMs, embedMs, searchMs },
    };
  };
}
