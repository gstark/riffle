// Confirms that domain-wide delegation works and prints the mailbox size.
// Usage: node src/sync/check-access.ts <service-account.json> <user@domain>

import { readFile } from "node:fs/promises";
import { gmailClient } from "./gmail-auth.ts";

interface GmailProfile {
  emailAddress: string;
  messagesTotal: number;
  threadsTotal: number;
  historyId: string;
}

const [keyFile, user] = process.argv.slice(2);
if (!keyFile || !user) {
  console.error("Usage: node src/sync/check-access.ts <service-account.json> <user@domain>");
  process.exit(1);
}

const client = gmailClient(await readFile(keyFile, "utf8"), user);
const { data } = await client.request<GmailProfile>({
  url: "https://gmail.googleapis.com/gmail/v1/users/me/profile",
});

console.log(`Mailbox:  ${data.emailAddress}`);
console.log(`Messages: ${data.messagesTotal}`);
console.log(`Threads:  ${data.threadsTotal}`);
console.log(`History:  ${data.historyId}`);
