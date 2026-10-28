# Receipts: the indexer sends the IDs of new messages to the receipts queue. The receipts Lambda drains it
# every minute, finds purchase emails, and writes the receipts table in the index bucket.
# It is the only writer of that table, so reserved concurrency is 1.

locals {
  receipts_function_name = "${var.name_prefix}-receipts"
}

resource "aws_sqs_queue" "receipts_dlq" {
  name                      = "${var.name_prefix}-receipts-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "receipts" {
  name                      = "${var.name_prefix}-receipts"
  message_retention_seconds = 1209600
  # Longer than one receipts run (15 minutes), so a batch in progress does not come back early.
  visibility_timeout_seconds = 960
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.receipts_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_cloudwatch_log_group" "receipts" {
  name              = "/aws/lambda/${local.receipts_function_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "receipts" {
  name                 = local.receipts_function_name
  permissions_boundary = local.role_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "receipts" {
  role = aws_iam_role.receipts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Without ListBucket, S3 returns AccessDenied instead of NoSuchKey for a missing object.
        Sid      = "ListBuckets"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = [aws_s3_bucket.archive.arn, aws_s3_bucket.index.arn]
      },
      {
        Sid      = "ReadArchiveMessages"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = ["${aws_s3_bucket.archive.arn}/meta/*", "${aws_s3_bucket.archive.arn}/raw/*"]
      },
      {
        Sid      = "ReadWriteIndex"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.index.arn}/*"
      },
      {
        Sid      = "UseArchiveKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.archive.arn
      },
      {
        Sid      = "ReadReceiptsQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.receipts.arn
      },
      # Haiku 5.5 through the US inference profile in us-east-1 (HAIKU_5_5_REGION in src/receipts/models.ts).
      # The profile can send a call to any US region. Converse needs bedrock:InvokeModel.
      {
        Sid    = "InvokeReceiptModel"
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        Resource = [
          "arn:aws:bedrock:us-east-1:${local.account_id}:inference-profile/us.anthropic.claude-haiku-5-5",
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-5-5",
        ]
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.receipts.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "receipts" {
  function_name = local.receipts_function_name
  role          = aws_iam_role.receipts.arn
  package_type  = "Image"
  image_uri     = local.search_image_uri
  architectures = ["arm64"]
  memory_size   = 2048
  timeout       = 900

  reserved_concurrent_executions = 1

  image_config {
    command = ["receipts-lambda.handler"]
  }

  environment {
    variables = {
      ARCHIVE_BUCKET = aws_s3_bucket.archive.id
      INDEX_BUCKET   = aws_s3_bucket.index.id
      QUEUE_URL      = aws_sqs_queue.receipts.url
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.receipts.name
  }

  depends_on = [aws_iam_role_policy.receipts]
}

# A start during an active run is throttled. Drop it: the next minute's start does the work.
resource "aws_lambda_function_event_invoke_config" "receipts" {
  function_name                = aws_lambda_function.receipts.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 60
}

resource "aws_scheduler_schedule" "receipts" {
  name                = local.receipts_function_name
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.receipts.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
