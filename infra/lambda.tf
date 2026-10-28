# Incremental sync: EventBridge Scheduler runs the Lambda every 5 minutes.
# Build the bundle first: npm run build:lambda

locals {
  sync_function_name = "${var.name_prefix}-sync"
  role_boundary_arn  = "arn:aws:iam::${local.account_id}:policy/${var.role_permissions_boundary}"
}

data "archive_file" "sync" {
  type        = "zip"
  source_file = "${path.module}/../dist/sync-lambda/index.cjs"
  output_path = "${path.module}/../dist/sync-lambda.zip"
}

resource "aws_cloudwatch_log_group" "sync" {
  name              = "/aws/lambda/${local.sync_function_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "sync" {
  name                 = local.sync_function_name
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

# Read and add to the archive. No delete permission.
resource "aws_iam_role_policy" "sync" {
  role = aws_iam_role.sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListArchive"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.archive.arn
      },
      {
        Sid      = "ReadWriteArchiveObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.archive.arn}/*"
      },
      {
        Sid      = "UseArchiveKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.archive.arn
      },
      {
        Sid      = "ReadGoogleKey"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.google_service_account.arn
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.sync.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "sync" {
  function_name    = local.sync_function_name
  role             = aws_iam_role.sync.arn
  runtime          = "nodejs24.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.sync.output_path
  source_code_hash = data.archive_file.sync.output_base64sha256
  memory_size      = 1024
  timeout          = 600

  # One run at a time. A run that is still busy makes the next one wait or drop.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      ARCHIVE_BUCKET   = aws_s3_bucket.archive.id
      GMAIL_USER       = var.gmail_user
      GOOGLE_SECRET_ID = aws_secretsmanager_secret.google_service_account.name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.sync.name
  }

  depends_on = [aws_iam_role_policy.sync]
}

# The next scheduled run is the retry, so Lambda must not retry or queue old runs.
resource "aws_lambda_function_event_invoke_config" "sync" {
  function_name                = aws_lambda_function.sync.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 240
}

resource "aws_iam_role" "scheduler" {
  name                 = "${var.name_prefix}-scheduler"
  permissions_boundary = local.role_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.sync.arn, aws_lambda_function.indexer.arn, aws_lambda_function.receipts.arn]
    }]
  })
}

resource "aws_scheduler_schedule" "sync" {
  name                = local.sync_function_name
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.sync.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
