# ===========================================================================
# LAYER 1 — AWS foundation: the permission-set catalog.
#
# WHAT a role name is allowed to do lives here, as code. WHO holds it, on
# WHICH account, lives in the Profiles (profiles/roles/*.yml -> cloud.aws.grants) and
# is realized by aws.tf (Layer 2). The two layers change at different speeds:
# this file changes rarely and deserves hard review; people changes flow
# through RBEC PRs without ever touching policy definitions.
#
# Keep this catalog SMALL (target: <= 5 sets). Person-level exceptions belong
# in role overrides, never as new one-off permission sets.
#
# Gated behind var.enable_aws, like all AWS resources. If this catalog ever
# graduates to a dedicated platform repo, replace the resources with data
# lookups and keep the names stable.
# ===========================================================================

locals {
  # name -> definition. Names are what RBEC roles reference in
  # cloud.aws.grants[].permissionSet — renaming here breaks roles; validate
  # before changing.
  permission_set_catalog = {
    ReadOnly = {
      description      = "See everything, change nothing. PMs, analysts, first-week joiners."
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      session_duration = "PT8H"
    }
    Developer = {
      description      = "Build and deploy, but no IAM/user/billing surface. Engineers day-to-day."
      managed_policies = ["arn:aws:iam::aws:policy/PowerUserAccess"]
      session_duration = "PT8H"
    }
    DevOpsEngineer = {
      description      = "Full administration for infrastructure work. Devops on non-prod accounts."
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      session_duration = "PT4H"
    }
    BreakGlassAdmin = {
      description      = "Emergency admin. 1-2 holders, short sessions, expect every use to be questioned."
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      session_duration = "PT1H"
    }
  }

  # (set, policy) pairs for the managed-policy attachments.
  permission_set_policies = merge([
    for set_name, ps in local.permission_set_catalog : {
      for policy_arn in ps.managed_policies :
      "${set_name}:${basename(policy_arn)}" => {
        set        = set_name
        policy_arn = policy_arn
      }
    }
  ]...)
}

resource "aws_ssoadmin_permission_set" "set" {
  for_each     = var.enable_aws ? local.permission_set_catalog : {}
  instance_arn = local.sso_instance_arn

  name             = each.key
  description      = each.value.description
  session_duration = each.value.session_duration

  tags = {
    ManagedBy = "fop-rbac"
  }
}

resource "aws_ssoadmin_managed_policy_attachment" "attach" {
  for_each     = var.enable_aws ? local.permission_set_policies : {}
  instance_arn = local.sso_instance_arn

  permission_set_arn = aws_ssoadmin_permission_set.set[each.value.set].arn
  managed_policy_arn = each.value.policy_arn
}

locals {
  # name -> ARN, consumed by the account assignments in aws.tf.
  permission_set_arns = {
    for name, ps in aws_ssoadmin_permission_set.set : name => ps.arn
  }
}
