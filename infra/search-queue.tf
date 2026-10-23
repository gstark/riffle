# Change feed for the search index. S3 sends every meta/ write in the archive bucket to this queue.
# The indexer Lambda reads it. The full build (src/search/enqueue-all.ts) also sends IDs to it.

resource "aws_sqs_queue" "index_dlq" {
  name                      = "${var.name_prefix}-index-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "index" {
  name                      = "${var.name_prefix}-index"
  message_retention_seconds = 1209600
  # Longer than one indexer run (15 minutes), so a batch in progress does not come back early.
  visibility_timeout_seconds = 960
  # SSE-SQS, not KMS: S3 can send to it without key permissions.
  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.index_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_policy" "index" {
  queue_url = aws_sqs_queue.index.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ArchiveBucketNotifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.index.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.archive.arn }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "archive" {
  bucket = aws_s3_bucket.archive.id

  queue {
    queue_arn     = aws_sqs_queue.index.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "meta/"
  }

  depends_on = [aws_sqs_queue_policy.index]
}
