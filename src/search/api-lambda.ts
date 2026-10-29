// Query Lambda entry point, behind a Function URL. See infra/search-api.tf.

import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import * as lancedb from "@lancedb/lancedb";
import { createSignedInProofs } from "../receipts/signed-in.ts";
import { openCandidateTables, readCandidates, writeSignedIn } from "../receipts/signed-in-table.ts";
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
const s3 = new S3Client();
const archiveBucket = requireEnv("ARCHIVE_BUCKET");
const source = createS3Source(s3, archiveBucket);

const getLabels = cached(() => source.getLabels(), CACHE_MS);

const getToken = cached(async () => {
  const secret = await secrets.send(new GetSecretValueCommand({ SecretId: tokenSecretId }));
  if (!secret.SecretString) throw new Error(`Secret ${tokenSecretId} has no value`);
  return secret.SecretString.trim();
}, CACHE_MS);

/** Connects once per Lambda instance. */
const getDb = cached(
  () => lancedb.connect(`s3://${requireEnv("INDEX_BUCKET")}`, { readConsistencyInterval: READ_CONSISTENCY_SECONDS }),
  Infinity,
);

/** Opens the table once per Lambda instance. */
const getTable = cached(async () => (await getDb()).openTable(TABLE), Infinity);

/** Opens the tables of the signed-in proofs once per Lambda instance. */
const getProofTables = cached(async () => openCandidateTables(await getDb()), Infinity);

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
  proofs: createSignedInProofs({
    pending: async () => readCandidates(await getProofTables()),
    candidate: async (id) => (await readCandidates(await getProofTables(), id))[0] ?? null,
    // The archive bucket has Object Lock, so S3 needs a checksum.
    putPdf: async (key, pdf) => {
      await s3.send(
        new PutObjectCommand({ Bucket: archiveBucket, Key: key, Body: pdf, ContentType: "application/pdf", ChecksumAlgorithm: "SHA256" }),
      );
    },
    write: async (row) => writeSignedIn((await getProofTables()).signedIn, row),
    now: () => new Date(),
  }),
  log,
});
