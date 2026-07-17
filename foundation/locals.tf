locals {
  common_tags = {
    ManagedBy = "terraform"
    Project   = "fop"
    Layer     = "foundation"
  }

  root_id = aws_organizations_organization.this.roots[0].id

  # Account key -> the OU it lands in. The key is also the logical name the
  # onboarding layer references via var.account_ids (see outputs.tf).
  ou_of = {
    "log-archive" = aws_organizations_organizational_unit.security.id
    "audit"       = aws_organizations_organizational_unit.security.id
    "sit"         = aws_organizations_organizational_unit.sdlc.id
    "staging"     = aws_organizations_organizational_unit.sdlc.id
    "production"  = aws_organizations_organizational_unit.prod.id
    "sandbox"     = aws_organizations_organizational_unit.sandbox.id
  }

  account_display = {
    "log-archive" = "Farmer1st Log Archive"
    "audit"       = "Farmer1st Security Audit"
    "sit"         = "Farmer1st SIT"
    "staging"     = "Farmer1st Staging"
    "production"  = "Farmer1st Production"
    "sandbox"     = "Farmer1st Sandbox"
  }

  # Unique root email per account: explicit override if given, else a plus-addressed
  # alias off the base mailbox.
  account_email = {
    for k in keys(local.ou_of) : k =>
    try(var.account_emails[k], replace(var.account_email_base, "@", "+fop-${k}@"))
  }
}
