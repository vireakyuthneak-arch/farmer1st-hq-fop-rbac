variable "management_region" {
  description = "Home region for the management account / org-level API calls."
  type        = string
  default     = "ap-southeast-1"
}

variable "allowed_regions" {
  description = "Regions workloads may operate in. The region-lock SCP denies everything else (global services excepted)."
  type        = list(string)
  default     = ["ap-southeast-1"]
}

variable "account_email_base" {
  description = <<-EOT
    Base mailbox for the auto-generated per-account root emails. Each account gets
    a plus-addressed alias, e.g. base "aws@farmer1st.org" -> "aws+fop-sit@farmer1st.org".
    Every AWS account needs a UNIQUE, deliverable root email; plus-addressing to one
    monitored inbox is the common practice. Override individual addresses below.
  EOT
  type        = string
  default     = "aws@farmer1st.org"
}

variable "account_emails" {
  description = "Optional per-account root email overrides, keyed by account key (sit, staging, production, sandbox, log-archive, audit)."
  type        = map(string)
  default     = {}
}

variable "org_service_access_principals" {
  description = "AWS services granted trusted access across the org (enables Identity Center, org-wide CloudTrail, Config)."
  type        = list(string)
  default = [
    "sso.amazonaws.com",
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
  ]
}

variable "expensive_services" {
  description = "Service prefixes the Sandbox OU may NOT use, to keep 'cheap mistakes' cheap. A starting list — tune to taste."
  type        = list(string)
  default = [
    "sagemaker:*",
    "redshift:*",
    "emr:*",
    "es:*",
    "elasticsearch:*",
    "glacier:*",
    "braket:*",
  ]
}

variable "offline" {
  description = "true (default) = placeholder creds + skip validation, for offline validate/plan (incl. moto). Set false for a real apply."
  type        = bool
  default     = true
}
