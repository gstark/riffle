// Runs one search on the messages table.

import type * as lancedb from "@lancedb/lancedb";
import type { Sort } from "./parse-query.ts";
import { arrowList } from "./schema.ts";

/** A search result before the API adds label names and the Gmail link. */
export interface Hit {
  id: string;
  threadId: string;
  date: Date;
  from: string;
  subject: string;
  snippet: string;
  /** Gmail label IDs. */
  labels: string[];
  hasAttachment: boolean;
}

export interface SearchRequest {
  /** Topic words. Empty for a filter-only search. */
  text: string;
  /** Embedding of `text`. Null when `text` is empty. */
  vector: number[] | null;
  where: string;
  sort: Sort;
  limit: number;
}

const COLUMNS = ["id", "threadId", "date", "from", "subject", "snippet", "labels", "hasAttachment"];
/** Topic matches that a date-sorted search orders by date. */
const DATE_SORT_POOL = 100;
/** Rows to get for each result, so enough remain after one message per thread is kept. */
const ROWS_PER_RESULT = 3;

function toHit(row: Record<string, unknown>): Hit {
  return {
    id: String(row.id),
    threadId: String(row.threadId),
    date: new Date(Number(row.date)),
    from: String(row.from),
    subject: String(row.subject),
    snippet: String(row.snippet),
    labels: arrowList(row.labels).map(String),
    hasAttachment: row.hasAttachment === true,
  };
}

/** Keeps the first hit of each thread. The order of the hits does not change. */
function onePerThread(hits: Hit[]): Hit[] {
  const seen = new Set<string>();
  return hits.filter((hit) => !seen.has(hit.threadId) && seen.add(hit.threadId));
}

export async function searchTable(
  table: lancedb.Table,
  { text, vector, where, sort, limit }: SearchRequest,
  reranker: lancedb.rerankers.Reranker,
): Promise<Hit[]> {
  let hits: Hit[];
  if (text && vector) {
    const rows: Record<string, unknown>[] = await table
      .query()
      .nearestTo(vector)
      .distanceType("cosine")
      .fullTextSearch(text, { columns: "text" })
      .where(where)
      .rerank(reranker)
      .select(COLUMNS)
      .limit(sort === "relevance" ? limit * ROWS_PER_RESULT : DATE_SORT_POOL)
      .toArray();
    hits = rows.map(toHit);
    if (sort !== "relevance") {
      const direction = sort === "oldest" ? 1 : -1;
      hits.sort((a, b) => direction * (a.date.getTime() - b.date.getTime()));
    }
  } else {
    const rows: Record<string, unknown>[] = await table
      .query()
      .where(where)
      .orderBy({ columnName: "date", ascending: sort === "oldest" })
      .select(COLUMNS)
      .limit(limit * ROWS_PER_RESULT)
      .toArray();
    hits = rows.map(toHit);
  }
  return onePerThread(hits).slice(0, limit);
}

/** The date of the newest message in the index, to show how up to date the index is. Null when the table is empty. */
export async function newestMessageDate(table: lancedb.Table): Promise<Date | null> {
  const rows: Record<string, unknown>[] = await table
    .query()
    .where("deleted = false")
    .orderBy({ columnName: "date", ascending: false })
    .select(["date"])
    .limit(1)
    .toArray();
  return rows[0] ? new Date(Number(rows[0].date)) : null;
}
