import { S3Client } from "@aws-sdk/client-s3";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { requireEnv } from "../shared/runtime.ts";
import { createS3Archive, type Archive } from "./archive.ts";
import { createGmailReader, type GmailReader } from "./gmail.ts";
import { gmailClient } from "./gmail-auth.ts";

/** Builds the Gmail reader and archive from ARCHIVE_BUCKET, GMAIL_USER, and GOOGLE_SECRET_ID. */
export async function connect(): Promise<{ gmail: GmailReader; archive: Archive }> {
  const bucket = requireEnv("ARCHIVE_BUCKET");
  const user = requireEnv("GMAIL_USER");
  const secretId = requireEnv("GOOGLE_SECRET_ID");

  const secret = await new SecretsManagerClient().send(new GetSecretValueCommand({ SecretId: secretId }));
  if (!secret.SecretString) throw new Error(`Secret ${secretId} has no value`);

  return {
    gmail: createGmailReader(gmailClient(secret.SecretString, user)),
    archive: createS3Archive(new S3Client(), bucket),
  };
}
