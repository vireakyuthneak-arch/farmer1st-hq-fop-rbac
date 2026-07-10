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

variable "account_ids" {
  type        = map(string)
  description = <<-EOT
    Maps the logical account names used in FOP roles (cloud.aws.account) to real
    12-digit AWS account IDs. Keeps account numbers out of the FOP spec.
  EOT
  default = {
    farmer1st-dev  = "111111111111"
    farmer1st-prod = "222222222222"
  }
}

variable "permission_set_arns" {
  type        = map(string)
  description = <<-EOT
    Maps the permission-set names used in FOP roles (cloud.aws.permissionSet) to
    their IAM Identity Center permission-set ARNs. Look these up once per org.
  EOT
  default = {
    DevOpsEngineer   = "arn:aws:sso:::permissionSet/ssoins-REPLACE/ps-REPLACE-devops"
    BackendDeveloper = "arn:aws:sso:::permissionSet/ssoins-REPLACE/ps-REPLACE-backend"
  }
}
