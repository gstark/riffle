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

Then apply the main stack:

```sh
cd infra
tofu init -backend-config=backend.hcl
tofu apply
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

A Lambda function runs every 5 minutes. It copies new messages, label changes, and deletions from Gmail to S3. Build the bundle before each apply:

```sh
npm run build:lambda
cd infra && tofu apply
```

Run a sync by hand:

```sh
AWS_PROFILE=automation aws lambda invoke --function-name email-backup-sync /dev/stdout
```

Logs are in the CloudWatch log group `/aws/lambda/email-backup-sync`. If the sync fails in 2 of 3 runs, or does not run for 30 minutes, an email goes to `alert_email`. You must confirm the SNS subscription email one time.

## Riffle

Riffle is the macOS menu bar app for the search API. See [apps/macos/Riffle/README.md](apps/macos/Riffle/README.md).
