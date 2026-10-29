# Search API: a Lambda Function URL for the Perch app. The handler checks a bearer token
# from Secrets Manager before it does any other work. See src/search/api.ts.

locals {
  search_function_name = "${var.name_prefix}-search"
}

# OpenTofu creates only the empty secret. Put the value with the AWS CLI (see README.md),
# so the token never enters OpenTofu state.
resource "aws_secretsmanager_secret" "search_token" {
  name                    = "${var.name_prefix}/search-token"
  kms_key_id              = aws_kms_key.archive.arn
  recovery_window_in_days = 7
}

resource "aws_cloudwatch_log_group" "search" {
  name              = "/aws/lambda/${local.search_function_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "search" {
  name                 = local.search_function_name
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

# Read: the index, the label names, the token, and the two Bedrock models.
# Write: only the signed_in_proofs table, and the signed-in PDFs that the Riffle app uploads with a presigned URL.
resource "aws_iam_role_policy" "search" {
  role = aws_iam_role.search.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListIndex"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.index.arn
      },
      {
        Sid      = "ReadIndex"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.index.arn}/*"
      },
      {
        Sid      = "ReadLabels"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.archive.arn}/state/labels.json"
      },
      {
        # LanceDB writes the table files and the version files under the table directory.
        Sid      = "WriteSignedInProofsTable"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.index.arn}/signed_in_proofs.lance/*"
      },
      {
        # A presigned URL uses the permissions of the role that signs it.
        Sid      = "PutSignedInPdfs"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.archive.arn}/proofs/*"
      },
      {
        # The result route lists the key to check that the Riffle app uploaded the PDF.
        Sid       = "ListProofs"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.archive.arn
        Condition = { StringLike = { "s3:prefix" = ["proofs/*"] } }
      },
      {
        Sid      = "UseArchiveKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.archive.arn
      },
      {
        Sid      = "ReadToken"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.search_token.arn
      },
      {
        Sid      = "Embed"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        # The query parser calls Claude through the Bedrock Mantle endpoint (AnthropicBedrockMantle).
        # Mantle serves Opus 5.5 in us-east-1 only (CLAUDE_REGION in src/search/parse-query.ts).
        Sid      = "InvokeClaude"
        Effect   = "Allow"
        Action   = "bedrock-mantle:CreateInference"
        Resource = "arn:aws:bedrock-mantle:us-east-1:${local.account_id}:project/default"
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.search.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "search" {
  function_name = local.search_function_name
  role          = aws_iam_role.search.arn
  package_type  = "Image"
  image_uri     = local.search_image_uri
  architectures = ["arm64"]
  # Lambda gives more CPU to more memory. LanceDB search uses the CPU.
  memory_size = 2048
  timeout     = 30

  # At most 5 searches at the same time. This limits the Bedrock cost if the token leaks.
  reserved_concurrent_executions = 5

  image_config {
    command = ["api-lambda.handler"]
  }

  environment {
    variables = {
      ARCHIVE_BUCKET  = aws_s3_bucket.archive.id
      INDEX_BUCKET    = aws_s3_bucket.index.id
      TOKEN_SECRET_ID = aws_secretsmanager_secret.search_token.name
      GMAIL_USER      = var.gmail_user
      TIME_ZONE       = var.time_zone
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.search.name
  }

  depends_on = [aws_iam_role_policy.search]
}

# Public URL. The handler checks the bearer token. Perch is a native app, so there is no CORS.
resource "aws_lambda_function_url" "search" {
  function_name      = aws_lambda_function.search.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "search_url" {
  statement_id           = "FunctionUrlPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.search.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "search_url_invoke" {
  statement_id             = "FunctionUrlInvokeFunction"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.search.function_name
  principal                = "*"
  invoked_via_function_url = true
}
