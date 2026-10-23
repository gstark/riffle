// Query Lambda entry point, behind a Function URL. See infra/search-api.tf.

import { S3Client } from "@aws-sdk/client-s3";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import * as lancedb from "@lancedb/lancedb";
import { log, requireEnv } from "../shared/runtime.ts";
import { createApi } from "./api.ts";
import { cached } from "./cache.ts";
import { createTitanEmbed } from "./embed.ts";
import { createClaudeReader } from "./parse-query.ts";
import { TABLE } from "./schema.ts";
import { newestMessageDate } from "./search.ts";
import { createSearch, labelList } from "./service.ts";
import { createS3Source } from "./source.ts";

/** A rotated token and renamed labels take effect within this time. */
const CACHE_MS = 5 * 60_000;
/** A warm Lambda checks for new table versions at most this often, in seconds. */
const READ_CONSISTENCY_SECONDS = 30;

const secrets = new SecretsManagerClient();
const tokenSecretId = requireEnv("TOKEN_SECRET_ID");
const source = createS3Source(new S3Client(), requireEnv("ARCHIVE_BUCKET"));

const getLabels = cached(() => source.getLabels(), CACHE_MS);

const getToken = cached(async () => {
  const secret = await secrets.send(new GetSecretValueCommand({ SecretId: tokenSecretId }));
  if (!secret.SecretString) throw new Error(`Secret ${tokenSecretId} has no value`);
  return secret.SecretString.trim();
}, CACHE_MS);

/** Opens the table once per Lambda instance. */
const getTable = cached(async () => {
  const db = await lancedb.connect(`s3://${requireEnv("INDEX_BUCKET")}`, {
    readConsistencyInterval: READ_CONSISTENCY_SECONDS,
  });
  return db.openTable(TABLE);
}, Infinity);

/** Builds the search once per Lambda instance. */
const getSearch = cached(async () => {
  return createSearch({
    table: await getTable(),
    reranker: await lancedb.rerankers.RRFReranker.create(),
    embed: createTitanEmbed(),
    read: createClaudeReader(),
    getLabels,
    gmailUser: requireEnv("GMAIL_USER"),
    timeZone: requireEnv("TIME_ZONE"),
    now: () => new Date(),
    log,
  });
}, Infinity);

export const handler = createApi({
  getToken,
  search: async (input, limit) => (await getSearch())(input, limit),
  labels: async () => labelList(await getLabels()),
  health: async () => {
    await getSearch();
    return newestMessageDate(await getTable());
  },
  log,
});
