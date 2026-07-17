# Organizational Units — the shape from AWS's Security Reference Architecture,
# trimmed to Farmer1st size:
#
#   root
#   ├── Security      (log-archive, audit)
#   ├── Workloads
#   │   ├── SDLC      (sit, staging)
#   │   └── Prod      (production)
#   └── Sandbox       (sandbox)
#
# SCPs attach to OUs (scps.tf), so the tree is also the guardrail boundary.

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = local.root_id
  tags      = local.common_tags
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = local.root_id
  tags      = local.common_tags
}

resource "aws_organizations_organizational_unit" "sdlc" {
  name      = "SDLC"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = local.common_tags
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = local.common_tags
}

resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = local.root_id
  tags      = local.common_tags
}
