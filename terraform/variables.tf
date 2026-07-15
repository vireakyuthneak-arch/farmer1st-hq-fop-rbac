variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "github_org" {
  type        = string
  description = "GitHub org that owns the teams (matches cloud.github.org in the roles)."
  default     = "farmer1st-hq"
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account id that owns the Zero Trust Access groups."
  default     = "REPLACE-with-cloudflare-account-id"
}

# KV-only token (scope: Workers KV Storage Edit + Account Read). Set as a
# second sensitive HCP workspace variable; local runs may leave it unset
# (falls back to CLOUDFLARE_API_TOKEN, then to the env var).
variable "CLOUDFLARE_KV_API_TOKEN" {
  type        = string
  description = "Cloudflare API token for the fop-rbac KV namespace (Workers KV Storage: Edit)."
  sensitive   = true
  default     = null
}

# Named to match the HCP workspace Terraform variable. When null (e.g. local
# runs via cf-onboard.sh), the provider falls back to the CLOUDFLARE_API_TOKEN
# environment variable — both storage styles work.
variable "CLOUDFLARE_API_TOKEN" {
  type        = string
  description = "Cloudflare API token (Members Edit + Access Edit + Account Read)."
  sensitive   = true
  default     = null
}

# Provider gates: Cloudflare goes live first. Flip these to true (as HCP
# workspace variables) once each provider's credentials + real values exist —
# until then, plans skip those resources entirely instead of failing.
variable "enable_aws" {
  type        = bool
  description = "Provision AWS Identity Center users + assignments."
  default     = false
}

variable "enable_github" {
  type        = bool
  description = "Provision GitHub org invites + team memberships."
  default     = false
}

variable "enable_cloudflare" {
  type        = bool
  description = "Provision Cloudflare Access groups + dashboard members."
  default     = true
}

variable "github_org_admins" {
  type        = list(string)
  description = <<-EOT
    GitHub usernames that hold org OWNER rights. Members of this list get
    role=admin in github_membership so Terraform never downgrades an owner
    to plain member.
  EOT
  default     = ["vireakyuth"]
}

variable "account_ids" {
  type        = map(string)
  description = <<-EOT
    Maps the logical account names used in FOP roles (cloud.aws.grants[].account)
    to real 12-digit AWS account IDs. Keeps account numbers out of the FOP spec.
    Permission sets are NOT mapped here — they are defined as code in
    aws-foundation.tf and referenced by name from the roles.
  EOT
  default = {
    farmer1st-dev  = "111111111111" # REPLACE with the real dev account id
    farmer1st-prod = "222222222222" # REPLACE with the real prod account id
  }
}
