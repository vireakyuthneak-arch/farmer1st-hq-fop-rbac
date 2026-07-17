# These outputs are the bridge to the Identity / onboarding layer (terraform/).
# account_ids maps 1:1 onto that layer's var.account_ids — wire them via HCP
# remote state (terraform_remote_state) or by copying values into the onboarding
# workspace, so environment names resolve to real account IDs in one place.

output "organization_id" {
  description = "The AWS Organization ID."
  value       = aws_organizations_organization.this.id
}

output "root_id" {
  description = "The organization root ID (SCP attachment target)."
  value       = local.root_id
}

output "ou_ids" {
  description = "OU name -> ID."
  value = {
    security  = aws_organizations_organizational_unit.security.id
    workloads = aws_organizations_organizational_unit.workloads.id
    sdlc      = aws_organizations_organizational_unit.sdlc.id
    prod      = aws_organizations_organizational_unit.prod.id
    sandbox   = aws_organizations_organizational_unit.sandbox.id
  }
}

output "account_ids" {
  description = "Account key -> account ID. Feed into the onboarding layer's var.account_ids."
  value       = { for k, a in aws_organizations_account.this : k => a.id }
}

output "account_emails" {
  description = "Account key -> root email (for the ops runbook)."
  value       = local.account_email
}
