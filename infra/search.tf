# Search index bucket: LanceDB tables built from the archive bucket.
# The index can be rebuilt from the archive at any time, so this bucket has no
# versioning or Object Lock. LanceDB rewrites and deletes its own files.

resource "aws_s3_bucket" "index" {
  bucket = "${var.name_prefix}-index-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "index" {
  bucket = aws_s3_bucket.index.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.archive.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "index" {
  bucket = aws_s3_bucket.index.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "index" {
  bucket = aws_s3_bucket.index.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.index.arn, "${aws_s3_bucket.index.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.index]
}

resource "aws_s3_bucket_lifecycle_configuration" "index" {
  bucket = aws_s3_bucket.index.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
