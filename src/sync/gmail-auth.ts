import { JWT } from "google-auth-library";

const GMAIL_READONLY = "https://www.googleapis.com/auth/gmail.readonly";

/**
 * Builds a client that acts as `user` through domain-wide delegation.
 * `serviceAccountJson` is the content of the service account JSON key.
 */
export function gmailClient(serviceAccountJson: string, user: string): JWT {
  const parsed: unknown = JSON.parse(serviceAccountJson);
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    !("client_email" in parsed) ||
    !("private_key" in parsed) ||
    typeof parsed.client_email !== "string" ||
    typeof parsed.private_key !== "string"
  ) {
    throw new Error("Service account JSON must contain client_email and private_key");
  }

  return new JWT({
    email: parsed.client_email,
    key: parsed.private_key,
    scopes: [GMAIL_READONLY],
    subject: user,
  });
}
