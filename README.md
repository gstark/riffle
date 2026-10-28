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

Logs are in the CloudWatch log group `/aws/lambda/email-backup-sync`. If the sync fails in 2 of 3 runs, or does not run for 30 minutes, an email goes to `alert_email`. You must confirm the SNS subscription email one time.

## Riffle

Riffle is the macOS menu bar app for the search API. See [apps/macos/Riffle/README.md](apps/macos/Riffle/README.md).

## Receipts

The receipts Lambda finds purchase emails (orders, subscription charges, refunds, and shipping notices) and writes their data to the `receipts` table in the index bucket. The indexer sends each new message to it. A keyword filter runs first, and only messages that pass go to the Bedrock model.

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

Logs are in the CloudWatch log group `/aws/lambda/email-backup-receipts`. A message that fails 5 times goes to the receipts dead-letter queue, and an email goes to `alert_email`.
