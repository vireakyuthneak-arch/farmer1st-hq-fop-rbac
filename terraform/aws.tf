# AWS access, derived from FOP roles, via IAM Identity Center (SSO).
#
# GATED behind var.enable_aws (default false): flip it on once Identity Center
# is enabled, the permission sets exist, and real ids/ARNs are in variables.tf.
#
# When enabled, onboarding is fully automated: for every user whose roles grant
# AWS access, Terraform CREATES their Identity Center user and assigns the
# role's permission set on the role's account. FOP never holds AWS credentials —
# the user signs in with `aws sso login` and receives short-lived tokens.
#
# NOTE: creating users this way assumes Identity Center is its own identity
# source. If you later federate it to an IdP (Google Workspace / Okta), users
# arrive via SCIM instead — switch this resource back to a data lookup.

data "aws_ssoadmin_instances" "this" {
  count = var.enable_aws ? 1 : 0
}

locals {
  sso_instance_arn  = var.enable_aws ? tolist(data.aws_ssoadmin_instances.this[0].arns)[0] : ""
  identity_store_id = var.enable_aws ? tolist(data.aws_ssoadmin_instances.this[0].identity_store_ids)[0] : ""
}

# Create one Identity Center user per AWS-entitled person in the RBEC.
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

resource "aws_ssoadmin_account_assignment" "assignment" {
  for_each           = var.enable_aws ? local.aws_assignments : {}
  instance_arn       = local.sso_instance_arn
  permission_set_arn = var.permission_set_arns[each.value.permission_set]

  principal_id   = aws_identitystore_user.user[each.value.aws_user].user_id
  principal_type = "USER"

  target_id   = var.account_ids[each.value.account]
  target_type = "AWS_ACCOUNT"
}
