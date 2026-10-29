output "archive_bucket" {
  value = aws_s3_bucket.archive.id
}

output "archive_kms_key_arn" {
  value = aws_kms_key.archive.arn
}

output "google_service_account_secret" {
  value = aws_secretsmanager_secret.google_service_account.name
}

output "index_bucket" {
  value = aws_s3_bucket.index.id
}

output "search_url" {
  value = aws_lambda_function_url.search.function_url
}

output "index_queue_url" {
  value = aws_sqs_queue.index.url
}

output "search_repository_url" {
  value = aws_ecr_repository.search.repository_url
}

output "search_token_secret" {
  value = aws_secretsmanager_secret.search_token.name
}

output "receipts_queue_url" {
  description = "Receipts queue. src/receipts/enqueue-receipts.ts sends the backfill IDs to it."
  value       = aws_sqs_queue.receipts.url
}

output "proofs_queue_url" {
  description = "Proofs queue. src/receipts/enqueue-proofs.ts sends the backfill IDs to it."
  value       = aws_sqs_queue.proofs.url
}

output "proofs_browser_id" {
  description = "AgentCore browser of the proofs Lambda. src/receipts/try-proofs.ts uses it."
  value       = aws_bedrockagentcore_browser.proofs.browser_id
}
