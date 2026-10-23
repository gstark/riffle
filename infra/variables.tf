variable "region" {
  type    = string
  default = "us-east-2"
}

variable "name_prefix" {
  type    = string
  default = "email-backup"
}

variable "object_lock_days" {
  description = "Default Object Lock retention (governance mode) for every object version in the archive bucket."
  type        = number
  default     = 365
}

variable "role_permissions_boundary" {
  description = "Path and name of the IAM policy that every role in this stack must use as its permissions boundary."
  type        = string
  default     = "automation/AutomationAgentsRoleBoundary"
}

variable "gmail_user" {
  description = "Google Workspace mailbox to back up. Set it in terraform.tfvars."
  type        = string
}

variable "alert_email" {
  description = "Email address for sync failure alerts. Set it in terraform.tfvars."
  type        = string
}

variable "time_zone" {
  description = "IANA time zone for dates in search queries, such as \"last week\"."
  type        = string
  default     = "America/New_York"
}
