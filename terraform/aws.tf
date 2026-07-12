# ===========================================================================
# LAYER 2 — AWS people: SSO users + account assignments, driven by the RBEC.
#
# For every user whose roles carry cloud.aws.grants, Terraform CREATES their
# IAM Identity Center user and assigns each granted permission set on each
# granted account. Nobody ever receives credentials: the user signs in with
# `aws sso login` and AWS mints short-lived tokens. Offboarding = delete the
# user's RBEC file -> user + every assignment revoked on the next apply.
#
# GATED behind var.enable_aws (default false). Go-live checklist:
#   1. Enable IAM Identity Center in the org's management account (console).
#   2. Put real account ids in var.account_ids.
#   3. Give the Terraform principal sso-admin + identitystore + orgs:List*.
#   4. Set enable_aws=true (HCP workspace variable).
#
# NOTE: creating users here assumes Identity Center is its own identity
# source. If it's ever federated to an IdP (Google Workspace/Okta), users
# arrive via SCIM — turn aws_identitystore_user into a data lookup and keep
# the assignments.
# ===========================================================================

data "aws_ssoadmin_instances" "this" {
  count = var.enable_aws ? 1 : 0
}

locals {
  sso_instance_arn  = var.enable_aws ? tolist(data.aws_ssoadmin_instances.this[0].arns)[0] : ""
  identity_store_id = var.enable_aws ? tolist(data.aws_ssoadmin_instances.this[0].identity_store_ids)[0] : ""
}

# One Identity Center user per AWS-entitled person in the RBEC.
resource "aws_identitystore_user" "user" {
  for_each          = var.enable_aws ? local.aws_identities : {}
  identity_store_id = local.identity_store_id

  user_name    = each.key
  display_name = each.value.full_name

  name {
    given_name  = split(" ", each.value.full_name)[0]
    family_name = length(split(" ", each.value.full_name)) > 1 ? join(" ", slice(split(" ", each.value.full_name), 1, length(split(" ", each.value.full_name)))) : each.value.full_name
  }

  emails {
    value   = each.value.email
    primary = true
  }
}

# One assignment per (user x account x permission set) grant from their roles.
resource "aws_ssoadmin_account_assignment" "assignment" {
  for_each     = var.enable_aws ? local.aws_assignments : {}
  instance_arn = local.sso_instance_arn

  permission_set_arn = local.permission_set_arns[each.value.permission_set]
  principal_id       = aws_identitystore_user.user[each.value.aws_user].user_id
  principal_type     = "USER"

  target_id   = var.account_ids[each.value.account]
  target_type = "AWS_ACCOUNT"

  lifecycle {
    precondition {
      condition     = contains(keys(local.permission_set_catalog), each.value.permission_set)
      error_message = "Role grant references permission set '${each.value.permission_set}', which is not in the catalog (terraform/aws-foundation.tf). Valid: ${join(", ", keys(local.permission_set_catalog))}."
    }
    precondition {
      condition     = contains(keys(var.account_ids), each.value.account)
      error_message = "Role grant references account '${each.value.account}', which is not in var.account_ids. Valid: ${join(", ", keys(var.account_ids))}."
    }
  }
}
