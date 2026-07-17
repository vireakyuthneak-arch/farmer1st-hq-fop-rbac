# One member account per environment / function. Terraform CAN create accounts
# (aws_organizations_account); it places each in its OU and creates the standard
# OrganizationAccountAccessRole the onboarding layer later assumes into.
#
# Guards:
#   prevent_destroy      — closing an AWS account is slow and irreversible-ish
#                          (90-day suspension); never let a plan delete one.
#   ignore_changes[role_name, name] — avoid churn if these drift.
#
# NOTE: real account creation is asynchronous and rate-limited by AWS; create a
# few at a time on the first real apply.
resource "aws_organizations_account" "this" {
  for_each = local.ou_of

  name      = local.account_display[each.key]
  email     = local.account_email[each.key]
  parent_id = each.value
  role_name = "OrganizationAccountAccessRole"

  # Keep the account open even if removed from config; close it deliberately by hand.
  close_on_deletion = false

  tags = merge(local.common_tags, {
    Environment = each.key
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, name]
  }
}
