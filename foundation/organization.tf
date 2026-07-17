# The AWS Organization itself. On a greenfield this resource CREATES the org from
# the management account. If an org already exists, import it once instead of
# recreating:  terraform import aws_organizations_organization.this o-xxxxxxxxxx
#
# feature_set = ALL is required for SCPs. We enable the SCP policy type here so the
# guardrail attachments in scps.tf have something to attach to.
resource "aws_organizations_organization" "this" {
  feature_set                   = "ALL"
  enabled_policy_types          = ["SERVICE_CONTROL_POLICY"]
  aws_service_access_principals = var.org_service_access_principals
}
