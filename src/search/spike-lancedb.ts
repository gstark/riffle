// Spike: index a sample of archived messages in LanceDB, then time keyword, vector, and hybrid queries.
//
//   node src/search/spike-lancedb.ts build <count> [uri]
//   node src/search/spike-lancedb.ts query <uri> "<text>[ :: <where>]"...
//
// uri defaults to .spike/lancedb. Needs ARCHIVE_BUCKET and AWS credentials.

import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import { GetObjectCommand, paginateListObjectsV2, S3Client } from "@aws-sdk/client-s3";
import * as lancedb from "@lancedb/lancedb";
import { Field, FixedSizeList, Float32, List, Schema, TimestampMillisecond, Utf8 } from "apache-arrow";
import PostalMime from "postal-mime";
import { MessageMetaSchema, metaKey } from "../shared/storage.ts";
import { runPool } from "../sync/pool.ts";

const DIMENSIONS = 1024;
const TABLE = "messages";
const MAX_TEXT = 8_000;

const schema = new Schema([
  new Field("id", new Utf8()),
  new Field("threadId", new Utf8()),
  new Field("date", new TimestampMillisecond()),
  new Field("from", new Utf8()),
  new Field("to", new Utf8()),
  new Field("subject", new Utf8()),
  new Field("labels", new List(new Field("item", new Utf8()))),
  new Field("text", new Utf8()),
  new Field("vector", new FixedSizeList(DIMENSIONS, new Field("item", new Float32()))),
]);

const s3 = new S3Client();
const bedrock = new BedrockRuntimeClient();
const bucket = process.env.ARCHIVE_BUCKET ?? "";

async function getObject(key: string): Promise<Uint8Array> {
  const object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  if (!object.Body) throw new Error(`${key} has no body`);
  return object.Body.transformToByteArray();
}

async function embed(text: string): Promise<number[]> {
  const response = await bedrock.send(
    new InvokeModelCommand({
      modelId: "amazon.titan-embed-text-v2:0",
      contentType: "application/json",
      body: JSON.stringify({ inputText: text.slice(0, MAX_TEXT), dimensions: DIMENSIONS, normalize: true }),
    }),
  );
  const { embedding } = JSON.parse(new TextDecoder().decode(response.body)) as { embedding: number[] };
  return embedding;
}

async function listRawKeys(count: number): Promise<string[]> {
  const keys: string[] = [];
  for await (const page of paginateListObjectsV2({ client: s3 }, { Bucket: bucket, Prefix: "raw/" })) {
    for (const object of page.Contents ?? []) if (object.Key) keys.push(object.Key);
  }
  // Random sample across all years (partial Fisher-Yates shuffle).
  for (let i = 0; i < Math.min(count, keys.length); i++) {
    const j = i + Math.floor(Math.random() * (keys.length - i));
    [keys[i], keys[j]] = [keys[j] as string, keys[i] as string];
  }
  return keys.slice(0, count);
}

const addresses = (list: { address?: string; name: string }[] | undefined) =>
  (list ?? []).map((a) => (a.address ? `${a.name} <${a.address}>` : a.name)).join(", ");

const stripHtml = (html: string) => html.replace(/<style[\s\S]*?<\/style>|<[^>]+>/g, " ").replace(/\s+/g, " ");

async function build(count: number, uri: string): Promise<void> {
  const keys = await listRawKeys(count);
  console.log(`Indexing ${keys.length} messages`);
  const rows: Record<string, unknown>[] = [];
  let started = Date.now();

  await runPool(keys, 16, async (key) => {
    const id = /([^/]+)\.eml$/.exec(key)?.[1] ?? key;
    const meta = MessageMetaSchema.parse(JSON.parse(new TextDecoder().decode(await getObject(metaKey(id)))));
    const email = await PostalMime.parse(await getObject(key));
    const body = email.text ?? stripHtml(email.html ?? "");
    const text = `${email.subject ?? ""}\n${body}`.trim();
    const from = addresses(email.from ? [email.from] : []);
    rows.push({
      id,
      threadId: meta.threadId,
      date: new Date(meta.internalDate),
      from,
      to: addresses(email.to),
      subject: email.subject ?? "",
      labels: meta.labelIds,
      text,
      vector: await embed(`From: ${from}\n${text}`),
    });
    if (rows.length % 100 === 0) console.log(`${rows.length} done`);
  });
  console.log(`Fetched, parsed, and embedded in ${((Date.now() - started) / 1000).toFixed(1)} s`);

  started = Date.now();
  const db = await lancedb.connect(uri);
  const table = await db.createTable(TABLE, lancedb.makeArrowTable(rows, { schema }), { mode: "overwrite" });
  await table.createIndex("text", { config: lancedb.Index.fts({ stem: true, removeStopWords: true }) });
  await table.createIndex("date", { config: lancedb.Index.btree() });
  await table.createIndex("labels", { config: lancedb.Index.labelList() });
  console.log(`Wrote table and indexes in ${((Date.now() - started) / 1000).toFixed(1)} s`);
}

async function timed<T>(run: () => Promise<T>): Promise<[T, string]> {
  const started = performance.now();
  const result = await run();
  return [result, `${(performance.now() - started).toFixed(0)} ms`];
}

/** Each query is "<text>" or "<text> :: <where>". */
async function query(uri: string, queries: string[]): Promise<void> {
  const columns = ["id", "date", "from", "subject"];
  const show = (rows: Record<string, unknown>[]) =>
    rows
      .slice(0, 3)
      .forEach((r) => console.log(`    ${new Date(r.date as number).toISOString().slice(0, 10)}  ${r.from}  ${r.subject}`));

  const [table, openTime] = await timed(async () => (await lancedb.connect(uri)).openTable(TABLE));
  console.log(`Opened table (${await table.countRows()} rows) in ${openTime}`);
  const rrf = await lancedb.rerankers.RRFReranker.create();

  for (const entry of queries) {
    const [text = "", where] = entry.split(" :: ");
    const filtered = <Q extends { where(predicate: string): Q }>(q: Q) => (where ? q.where(where) : q);
    const [vector, embedTime] = await timed(() => embed(text));
    const [keyword, keywordTime] = await timed(() =>
      filtered(table.query().fullTextSearch(text)).select(columns).limit(10).toArray(),
    );
    const [nearest, vectorTime] = await timed(() =>
      filtered(table.query().nearestTo(vector)).select(columns).limit(10).toArray(),
    );
    const [hybrid, hybridTime] = await timed(() =>
      filtered(table.query().nearestTo(vector).fullTextSearch(text).rerank(rrf)).select(columns).limit(10).toArray(),
    );
    console.log(`\n"${entry}"  embed ${embedTime}, keyword ${keywordTime}, vector ${vectorTime}, hybrid ${hybridTime}`);
    console.log("  Keyword:");
    show(keyword);
    console.log("  Vector:");
    show(nearest);
    console.log("  Hybrid:");
    show(hybrid);
  }
}

const [command, arg = "", ...rest] = process.argv.slice(2);
if (command === "build") await build(Number(arg), rest[0] ?? ".spike/lancedb");
else if (command === "query" && rest.length > 0) await query(arg, rest);
else throw new Error('Usage: build <count> [uri] | query <uri> "<text>[ :: <where>]"...');
