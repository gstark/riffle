# Search indexer: drains the index queue every minute and writes the LanceDB table.
# It is the only writer of the table, so reserved concurrency is 1.

locals {
  indexer_function_name = "${var.name_prefix}-indexer"
}

resource "aws_cloudwatch_log_group" "indexer" {
  name              = "/aws/lambda/${local.indexer_function_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "indexer" {
  name                 = local.indexer_function_name
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

resource "aws_iam_role_policy" "indexer" {
  role = aws_iam_role.indexer.id

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
        Sid      = "ReadIndexQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.index.arn
      },
      {
        Sid      = "Embed"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.indexer.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "indexer" {
  function_name = local.indexer_function_name
  role          = aws_iam_role.indexer.arn
  package_type  = "Image"
  image_uri     = local.search_image_uri
  architectures = ["arm64"]
  # Index creation after the full build trains IVF-PQ on all vectors. It needs the memory.
  memory_size = 3008
  timeout     = 900

  reserved_concurrent_executions = 1

  ephemeral_storage {
    size = 4096
  }

  image_config {
    command = ["indexer-lambda.handler"]
  }

  environment {
    variables = {
      ARCHIVE_BUCKET = aws_s3_bucket.archive.id
      INDEX_BUCKET   = aws_s3_bucket.index.id
      QUEUE_URL      = aws_sqs_queue.index.url
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.indexer.name
  }

  depends_on = [aws_iam_role_policy.indexer]
}

# A start during an active run is throttled. Drop it: the next minute's start does the work.
resource "aws_lambda_function_event_invoke_config" "indexer" {
  function_name                = aws_lambda_function.indexer.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 60
}

resource "aws_scheduler_schedule" "indexer" {
  name                = local.indexer_function_name
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.indexer.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
