# Google service account JSON key. OpenTofu creates only the empty secret.
# Put the value with the AWS CLI so the key never enters OpenTofu state:
#   aws secretsmanager put-secret-value --secret-id <name> --secret-string file://key.json

resource "aws_secretsmanager_secret" "google_service_account" {
  name                    = "${var.name_prefix}/google-service-account"
  kms_key_id              = aws_kms_key.archive.arn
  recovery_window_in_days = 7
}
