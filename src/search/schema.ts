// LanceDB table layout for the search index.

import { Bool, Field, FixedSizeList, Float32, List, Schema, TimestampMillisecond, Utf8 } from "apache-arrow";

export const TABLE = "messages";
export const DIMENSIONS = 1024;

export const schema = new Schema([
  new Field("id", new Utf8()),
  new Field("threadId", new Utf8()),
  new Field("date", new TimestampMillisecond()),
  new Field("from", new Utf8()),
  new Field("fromKey", new Utf8()),
  new Field("to", new Utf8()),
  new Field("toKey", new Utf8()),
  new Field("subject", new Utf8()),
  new Field("labels", new List(new Field("item", new Utf8()))),
  new Field("attachments", new Utf8()),
  new Field("hasAttachment", new Bool()),
  new Field("snippet", new Utf8()),
  new Field("text", new Utf8()),
  new Field("vector", new FixedSizeList(DIMENSIONS, new Field("item", new Float32()))),
  new Field("deleted", new Bool()),
]);

/** One row of the messages table. */
export type IndexRow = {
  id: string;
  threadId: string;
  date: Date;
  from: string;
  /** Lower-case `from`, for the sender filter. */
  fromKey: string;
  to: string;
  /** Lower-case `to`, for the recipient filter. */
  toKey: string;
  subject: string;
  /** Gmail label IDs. */
  labels: string[];
  /** Attachment filenames, separated by spaces. */
  attachments: string;
  hasAttachment: boolean;
  snippet: string;
  /** Subject, attachment filenames, and body, for full-text search. */
  text: string;
  vector: number[];
  /** True when the message was deleted in Gmail. */
  deleted: boolean;
};

/** Converts an Arrow list value from `toArray()` to a plain array. */
export function arrowList(value: unknown): unknown[] {
  if (value === null || value === undefined) return [];
  if (typeof value === "object" && Symbol.iterator in value) return Array.from(value as Iterable<unknown>);
  throw new Error(`Expected a list, got ${typeof value}`);
}

/** Converts a full row from `toArray()`. Lists come back as Arrow vectors and dates as numbers. */
export function toIndexRow(row: Record<string, unknown>): IndexRow {
  const text = (name: string) => String(row[name] ?? "");
  return {
    id: text("id"),
    threadId: text("threadId"),
    date: new Date(Number(row.date)),
    from: text("from"),
    fromKey: text("fromKey"),
    to: text("to"),
    toKey: text("toKey"),
    subject: text("subject"),
    labels: arrowList(row.labels).map(String),
    attachments: text("attachments"),
    hasAttachment: row.hasAttachment === true,
    snippet: text("snippet"),
    text: text("text"),
    vector: arrowList(row.vector).map(Number),
    deleted: row.deleted === true,
  };
}
