# Archive bucket: the source of truth for all mail.
#   raw/<yyyy>/<mm>/<gmail-id>.eml  original RFC 822 message, never overwritten
#   meta/<gmail-id>.json            labels, thread id, deleted-in-gmail flag
#   state/sync.json, labels.json    sync cursor (Gmail history ID), label names

resource "aws_kms_key" "archive" {
  description             = "${var.name_prefix} archive bucket encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "archive" {
  name          = "alias/${var.name_prefix}-archive"
  target_key_id = aws_kms_key.archive.key_id
}

resource "aws_s3_bucket" "archive" {
  bucket              = "${var.name_prefix}-archive-${local.account_id}"
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.archive]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.archive.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket = aws_s3_bucket.archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.archive]
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"
    filter {}

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # meta/ and state/ objects are rewritten by every sync. Old versions stay
  # locked for object_lock_days, then expire. raw/ objects are never rewritten.
  dynamic "rule" {
    for_each = ["meta", "state"]

    content {
      id     = "expire-old-${rule.value}-versions"
      status = "Enabled"

      filter {
        prefix = "${rule.value}/"
      }

      noncurrent_version_expiration {
        noncurrent_days = var.object_lock_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.archive]
}
