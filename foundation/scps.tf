# Service Control Policies — the org-wide ceiling. They apply to EVERY principal
# in the targeted accounts, including admins and the tf-<env> pipeline roles, so
# they are the backstop no role can exceed.
#
# These are DENY policies layered on top of the default FullAWSAccess (which we do
# NOT remove) — the model is "allow by default, deny the dangerous things".

locals {
  # Global services that are region-agnostic and must stay reachable even under a
  # region lock (they only exist in us-east-1 / are truly global).
  global_service_exceptions = [
    "a4b:*", "account:*", "acm:*", "aws-marketplace:*", "aws-marketplace-management:*",
    "aws-portal:*", "budgets:*", "ce:*", "cloudfront:*", "config:*", "cur:*",
    "directconnect:*", "globalaccelerator:*", "health:*", "iam:*", "kms:*",
    "organizations:*", "pricing:*", "route53:*", "route53domains:*", "shield:*",
    "sso:*", "sts:*", "support:*", "trustedadvisor:*", "waf:*", "wafv2:*",
    "wellarchitected:*",
  ]

  # 1) Baseline — attached at the root, applies everywhere below it.
  scp_baseline = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyLeavingOrg"
        Effect   = "Deny"
        Action   = ["organizations:LeaveOrganization"]
        Resource = "*"
      },
      {
        Sid    = "ProtectCloudTrail"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging",
          "cloudtrail:DeleteTrail",
          "cloudtrail:UpdateTrail",
          "cloudtrail:PutEventSelectors",
        ]
        Resource = "*"
      },
      {
        Sid    = "ProtectConfig"
        Effect = "Deny"
        Action = [
          "config:DeleteConfigurationRecorder",
          "config:StopConfigurationRecorder",
          "config:DeleteDeliveryChannel",
        ]
        Resource = "*"
      },
      {
        # The account root user should never be used for day-to-day actions.
        Sid       = "DenyRootUser"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringLike = { "aws:PrincipalArn" = ["arn:aws:iam::*:root"] } }
      },
    ]
  })

  # 2) Region lock — attached to Workloads + Sandbox OUs (NOT root, so the
  #    management/security accounts keep full regional reach for org ops).
  scp_region_lock = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyOutsideAllowedRegions"
        Effect    = "Deny"
        NotAction = local.global_service_exceptions
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } }
      },
    ]
  })

  # 3) Sandbox limits — keep experimentation cheap.
  scp_sandbox_limits = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyExpensiveServices"
        Effect   = "Deny"
        Action   = var.expensive_services
        Resource = "*"
      },
    ]
  })

  # 4) Prod protection — make the destructive things hard.
  scp_prod_protect = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ProtectEncryptionKeys"
        Effect   = "Deny"
        Action   = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
        Resource = "*"
      },
      {
        Sid      = "ProtectBackups"
        Effect   = "Deny"
        Action   = ["backup:DeleteBackupVault", "dynamodb:DeleteBackup"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_organizations_policy" "baseline" {
  name        = "fop-baseline-guardrails"
  description = "Org-wide: protect logging, block leaving the org, deny root-user actions."
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_baseline
  tags        = local.common_tags
}

resource "aws_organizations_policy" "region_lock" {
  name        = "fop-region-lock"
  description = "Deny workloads outside var.allowed_regions (global services excepted)."
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_region_lock
  tags        = local.common_tags
}

resource "aws_organizations_policy" "sandbox_limits" {
  name        = "fop-sandbox-limits"
  description = "Deny expensive services in the Sandbox OU."
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_sandbox_limits
  tags        = local.common_tags
}

resource "aws_organizations_policy" "prod_protect" {
  name        = "fop-prod-protect"
  description = "Deny destructive key/backup actions in the Prod OU."
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_prod_protect
  tags        = local.common_tags
}

# ---- attachments ----
resource "aws_organizations_policy_attachment" "baseline_root" {
  policy_id = aws_organizations_policy.baseline.id
  target_id = local.root_id
}

resource "aws_organizations_policy_attachment" "region_lock_workloads" {
  policy_id = aws_organizations_policy.region_lock.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy_attachment" "region_lock_sandbox" {
  policy_id = aws_organizations_policy.region_lock.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}

resource "aws_organizations_policy_attachment" "sandbox_limits" {
  policy_id = aws_organizations_policy.sandbox_limits.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}

resource "aws_organizations_policy_attachment" "prod_protect" {
  policy_id = aws_organizations_policy.prod_protect.id
  target_id = aws_organizations_organizational_unit.prod.id
}
