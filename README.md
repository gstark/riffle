# Riffle

Backs up a Google Workspace mailbox to S3 and indexes it for search.

## Requirements

- Node 24 or later
- OpenTofu 1.10 or later
- AWS credentials for the target account

## Checks

```sh
npm install
npm run typecheck
npm run lint
npm test
```

## Infrastructure

Run the bootstrap stack one time per AWS account. It creates the state bucket and writes `infra/backend.hcl`. Git ignores that file. Run the bootstrap again to write it on a new machine.

```sh
cd infra/bootstrap
tofu init
tofu apply
```

Copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and set the mailbox and the alert address. Git ignores `terraform.tfvars`.

Then apply the main stack. The recipe initializes the backend, builds the sync Lambda bundle, and runs `tofu apply`:

```sh
just deploy
```

The bootstrap stack keeps its state in `infra/bootstrap/terraform.tfstate`. Git ignores that file. If you lose it, run `tofu import` on the state bucket.

The archive bucket and its KMS key have `prevent_destroy`. Every object version has Object Lock retention in governance mode (default 365 days).

## Backfill

Put the Google service account key into Secrets Manager one time:

```sh
aws secretsmanager put-secret-value \
  --secret-id email-backup/google-service-account \
  --secret-string file://path/to/key.json
```

Then copy all mail to S3:

```sh
ARCHIVE_BUCKET=$(cd infra && tofu output -raw archive_bucket) \
GMAIL_USER=you@example.com \
GOOGLE_SECRET_ID=email-backup/google-service-account \
AWS_REGION=us-east-2 \
node src/sync/run-backfill.ts
```

You can stop the backfill and run it again. It skips messages that are already in S3. If any message fails, run it again.

## Incremental sync

A Lambda function runs every 5 minutes. It copies new messages, label changes, and deletions from Gmail to S3. Deploy a change to it, or to the infrastructure, with:

```sh
just deploy
```

The recipe builds the bundle, initializes the backend, and runs `tofu apply`. To deploy the search service, run `just deploy-search` instead. It also pushes the search image.

Run a sync by hand:

```sh
AWS_PROFILE=automation aws lambda invoke --function-name email-backup-sync /dev/stdout
```

The archive keeps trash, but not spam. When a message moves to spam, the sync sets `deletedAt` on it. When it leaves spam, the sync clears `deletedAt`. Search and receipts skip deleted messages.

Logs are in the CloudWatch log group `/aws/lambda/email-backup-sync`. If the sync fails in 2 of 3 runs, or does not run for 30 minutes, an email goes to `alert_email`. You must confirm the SNS subscription email one time.

## Riffle

Riffle is the macOS menu bar app for the search API. See [apps/macos/Riffle/README.md](apps/macos/Riffle/README.md).

## Receipts

The receipts Lambda finds purchase emails (orders, subscription charges, refunds, and shipping notices) and writes their data to the `receipts` table in the index bucket. The indexer sends each new message to it. A keyword filter runs first, and only messages that pass go to the Bedrock model.

The table has one row for each receipt. An email can have more than one receipt, for example an Amazon confirmation of two orders. Then each order gets its own row with its own total. The `messageId` column holds the Gmail message ID, and `id` is `<messageId>:<n>`. A message without receipts has one row with kind `none`.

Process the last 24 months of archived mail one time:

```sh
AWS_PROFILE=automation AWS_REGION=us-east-2 \
ARCHIVE_BUCKET=$(cd infra && tofu output -raw archive_bucket) \
RECEIPTS_QUEUE_URL=$(cd infra && tofu output -raw receipts_queue_url) \
node src/receipts/enqueue-receipts.ts
```

Set `MONTHS` to change the range. Messages that already have a row are skipped, so the script can run again.

Show the counts and the newest receipts:

```sh
AWS_PROFILE=automation AWS_REGION=us-east-2 \
INDEX_BUCKET=$(cd infra && tofu output -raw index_bucket) \
node src/receipts/show-receipts.ts
```

After a change to the filter rules or the prompt, increase `RECEIPTS_VERSION` in `src/receipts/row.ts` and run the backfill again.

A full rebuild of the search index sends every archived message to the receipts queue, not only the last 24 months. That costs about $20 in model calls.

### Proof of purchase

The proofs Lambda keeps a proof of purchase for each receipt. The receipts Lambda sends each message with a receipt to the proofs queue. For each message, the proofs Lambda:

1. Stores a PDF of the email at `proofs/<messageId>/email.pdf` in the archive bucket. Every receipt has this PDF.
2. Stores each PDF attachment at `proofs/<messageId>/attachment-<n>.pdf`. Then it does not open links.
3. Otherwise, selects the links that can go to a receipt page with rules. It never opens links that unsubscribe or change the account.
4. Opens at most 3 links in an Amazon Bedrock AgentCore browser. It does not sign in. After a sign-in page or a block, it skips the other links to that site.
5. Stores a PDF of a page or a downloaded PDF at `proofs/<messageId>/link-<n>.pdf`.

It writes one row for each receipt to the `receipt_proofs` table in the index bucket. The `fidelity` column tells how much the best proof shows, best first:

- `attached_pdf`: the email has a PDF attachment.
- `merchant_pdf`: a link gave a PDF file.
- `merchant_page`: a page shows the total or the order ID.
- `unverified_page`: a page opened, but it does not show them.
- `login_required`: the link goes to a sign-in page.
- `blocked`: the site refused the browser (status 403 or 429, or a CAPTCHA).
- `link_failed`: an HTTP error, a timeout, or an expired link.
- `no_link`: the email has no receipt link.

`pdfKey` is the PDF of the best proof. `emailPdfKey` is the email PDF. `documents` lists all stored PDFs with their SHA-256. `attempts` lists each link visit.

Chromium runs in AgentCore, not in the Lambda. The proofs Lambda uses the search image, so `just deploy-search` deploys it. The AgentCore browser has Web Bot Auth: it signs its requests, so sites that use Cloudflare, Akamai, or HUMAN Security can identify it as a known agent. Its user agent says `Amazon-Bedrock-AgentCore-Browser`.

Send the messages with receipts that have no proof to the proofs queue:

```sh
AWS_PROFILE=automation AWS_REGION=us-east-2 \
INDEX_BUCKET=$(cd infra && tofu output -raw index_bucket) \
PROOFS_QUEUE_URL=$(cd infra && tofu output -raw proofs_queue_url) \
node src/receipts/enqueue-proofs.ts
```

Set `LIMIT` to send a random sample. After a change to the link rules or the classification, increase `PROOFS_VERSION` in `src/receipts/proof-table.ts` and run the script again.

To see the results without storing anything, run `try-proofs.ts`. It uses the same AgentCore browser. The PDFs stay in memory.

```sh
AWS_PROFILE=automation AWS_REGION=us-east-2 \
INDEX_BUCKET=$(cd infra && tofu output -raw index_bucket) \
ARCHIVE_BUCKET=$(cd infra && tofu output -raw archive_bucket) \
BROWSER_ID=$(cd infra && tofu output -raw proofs_browser_id) \
node src/receipts/try-proofs.ts 40
```

Logs are in the CloudWatch log groups `/aws/lambda/email-backup-receipts` and `/aws/lambda/email-backup-proofs`. A message that fails 5 times goes to the dead-letter queue of its step, and an email goes to `alert_email`.
