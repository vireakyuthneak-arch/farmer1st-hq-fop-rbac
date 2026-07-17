# ===========================================================================
# LAYER 1 — AWS foundation: the permission-set catalog (the persona vocabulary).
#
# WHAT a permission-set name is allowed to do lives here, as code. WHO holds it,
# on WHICH account, lives in the Profiles (profiles/roles/*.yml -> cloud.aws.grants)
# and is realized by aws.tf (Layer 2). The two layers change at different speeds:
# this file changes rarely and deserves hard review; people changes flow through
# RBAC PRs without ever touching policy definitions.
#
# Access model (see the architecture plan): standing access is read-only by
# default; write is the exception.
#   ViewOnly      metadata/config only, NO secret values or data-plane reads
#   ReadOnly      broad read (can see secret/object contents — use sparingly)
#   PowerUser     full build/deploy, no IAM/org/billing — sandbox + dev work
#   DevOpsOps     ReadOnly + operational actions (SSM sessions, restart, logs)
#   Admin         full admin — DEFINED here but never granted standing; the JIT
#                 system assigns it temporarily (Zero Standing Privileges)
#   SecurityAudit read + security services, for the Audit account
#   BreakGlass    sealed emergency admin — 1-2 holders, short session, loud alarms
#
# Admin + BreakGlass exist in the catalog so JIT/emergency flows can assign them,
# but NO role's cloud.aws.grants references them — they are never standing access.
#
# Gated behind var.enable_aws, like all AWS resources.
# ===========================================================================

locals {
  # Operational actions layered on top of ReadOnly for the DevOpsOps set — enough
  # to run non-prod without break-glass (open a Session Manager shell, restart a
  # service, read logs) without full admin. Starting list; scope by resource/tag
  # as the estate matures.
  devops_ops_inline = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SessionManager"
        Effect = "Allow"
        Action = [
          "ssm:StartSession", "ssm:ResumeSession", "ssm:TerminateSession",
          "ssm:DescribeSessions", "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation", "ssm:SendCommand", "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
      {
        Sid    = "RestartWorkloads"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService", "ecs:StopTask",
          "ec2:RebootInstances",
          "lambda:UpdateFunctionConfiguration",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
        Resource = "*"
      },
    ]
  })

  # name -> definition. Names are what roles reference in
  # cloud.aws.grants[].permissionSet — renaming here breaks roles; validate
  # before changing. Every entry carries the same shape (inline_policy = null
  # when there is no customer inline policy).
  permission_set_catalog = {
    ViewOnly = {
      description      = "See infra/config metadata, no data or secret values. Prod read-only baseline."
      managed_policies = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      inline_policy    = null
      session_duration = "PT8H"
    }
    ReadOnly = {
      description      = "Broad read (incl. secret/object contents). Use where full visibility is needed."
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policy    = null
      session_duration = "PT8H"
    }
    PowerUser = {
      description      = "Build and deploy, no IAM/org/billing. Sandbox for everyone; dev work."
      managed_policies = ["arn:aws:iam::aws:policy/PowerUserAccess"]
      inline_policy    = null
      session_duration = "PT8H"
    }
    DevOpsOps = {
      description      = "ReadOnly + operational actions (SSM sessions, restart, logs). DevOps in non-prod."
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policy    = local.devops_ops_inline
      session_duration = "PT4H"
    }
    Admin = {
      description      = "Full admin. JIT-ONLY — never granted standing; the elevation flow assigns it temporarily."
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      inline_policy    = null
      session_duration = "PT2H"
    }
    SecurityAudit = {
      description = "Read + security services, for the Audit account."
      managed_policies = [
        "arn:aws:iam::aws:policy/SecurityAudit",
        "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
      ]
      inline_policy    = null
      session_duration = "PT8H"
    }
    BreakGlass = {
      description      = "Sealed emergency admin. 1-2 holders, short session, expect every use to be questioned."
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      inline_policy    = null
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

  # sets that carry a customer inline policy.
  permission_set_inline = {
    for set_name, ps in local.permission_set_catalog :
    set_name => ps.inline_policy if ps.inline_policy != null
  }
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

resource "aws_ssoadmin_permission_set_inline_policy" "inline" {
  for_each     = var.enable_aws ? local.permission_set_inline : {}
  instance_arn = local.sso_instance_arn

  permission_set_arn = aws_ssoadmin_permission_set.set[each.key].arn
  inline_policy      = each.value
}

locals {
  # name -> ARN, consumed by the account assignments in aws.tf.
  permission_set_arns = {
    for name, ps in aws_ssoadmin_permission_set.set : name => ps.arn
  }
}
