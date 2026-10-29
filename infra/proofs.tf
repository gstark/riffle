# Proofs of purchase: the receipts Lambda sends the IDs of messages with receipts to the proofs queue.
# The proofs Lambda drains it every minute. For each email it stores a PDF of the email, its PDF attachments,
# and PDFs of receipt links that open without a sign-in, under proofs/ in the archive bucket.
# It writes the receipt_proofs table in the index bucket. It is the only writer, so reserved concurrency is 1.
#
# Chromium runs in an Amazon Bedrock AgentCore browser, not in the Lambda. The Lambda uses the search image.

locals {
  proofs_function_name = "${var.name_prefix}-proofs"
}

# Web Bot Auth (browser_signing) signs the browser's requests, so Cloudflare, Akamai, and HUMAN Security
# can identify it as a known agent and show fewer CAPTCHAs.
resource "aws_bedrockagentcore_browser" "proofs" {
  # Browser names allow only letters, digits, and underscores.
  name        = "${replace(var.name_prefix, "-", "_")}_proofs"
  description = "Opens receipt links and renders proof of purchase PDFs."
  # Web Bot Auth needs a role. It needs no permissions.
  execution_role_arn = aws_iam_role.proofs_browser.arn

  network_configuration {
    network_mode = "PUBLIC"
  }

  browser_signing {
    enabled = true
  }
}

resource "aws_iam_role" "proofs_browser" {
  name                 = "${local.proofs_function_name}-browser"
  permissions_boundary = local.role_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_sqs_queue" "proofs_dlq" {
  name                      = "${var.name_prefix}-proofs-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "proofs" {
  name                      = "${var.name_prefix}-proofs"
  message_retention_seconds = 1209600
  # Longer than one proofs run (15 minutes), so a batch in progress does not come back early.
  visibility_timeout_seconds = 960
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.proofs_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_cloudwatch_log_group" "proofs" {
  name              = "/aws/lambda/${local.proofs_function_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "proofs" {
  name                 = local.proofs_function_name
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

resource "aws_iam_role_policy" "proofs" {
  role = aws_iam_role.proofs.id

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
        Sid      = "WriteProofs"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.archive.arn}/proofs/*"
      },
      {
        # The receipts table is read. The receipt_proofs table is written.
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
        Sid      = "ReadProofsQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.proofs.arn
      },
      {
        Sid    = "UseBrowser"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:StartBrowserSession",
          "bedrock-agentcore:StopBrowserSession",
          "bedrock-agentcore:ConnectBrowserAutomationStream",
        ]
        Resource = aws_bedrockagentcore_browser.proofs.browser_arn
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.proofs.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "proofs" {
  function_name = local.proofs_function_name
  role          = aws_iam_role.proofs.arn
  package_type  = "Image"
  image_uri     = local.search_image_uri
  architectures = ["arm64"]
  memory_size   = 2048
  timeout       = 900

  reserved_concurrent_executions = 1

  image_config {
    command = ["proofs-lambda.handler"]
  }

  environment {
    variables = {
      ARCHIVE_BUCKET = aws_s3_bucket.archive.id
      BROWSER_ID     = aws_bedrockagentcore_browser.proofs.browser_id
      INDEX_BUCKET   = aws_s3_bucket.index.id
      QUEUE_URL      = aws_sqs_queue.proofs.url
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.proofs.name
  }

  depends_on = [aws_iam_role_policy.proofs]
}

# A start during an active run is throttled. Drop it: the next minute's start does the work.
resource "aws_lambda_function_event_invoke_config" "proofs" {
  function_name                = aws_lambda_function.proofs.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 60
}

resource "aws_scheduler_schedule" "proofs" {
  name                = local.proofs_function_name
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.proofs.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}

# A message failed 5 times and is in the proofs dead-letter queue.
resource "aws_cloudwatch_metric_alarm" "proofs_dlq" {
  alarm_name          = "${var.name_prefix}-proofs-dlq"
  alarm_description   = "A message failed the proof of purchase step 5 times and is in the proofs dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.proofs_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "proofs_errors" {
  alarm_name          = "${local.proofs_function_name}-errors"
  alarm_description   = "The proofs Lambda failed in 2 of the last 3 five-minute periods."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.proofs.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
