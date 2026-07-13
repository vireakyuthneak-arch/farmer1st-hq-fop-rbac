# Cloudflare access, derived from FOP roles, via Zero Trust Access groups.
#
# Each role lists cloud.cloudflare.accessGroups; Terraform materializes every
# group with its member emails (unioned across users' roles). Access policies
# on protected apps / WARP then reference these groups by name — so who can
# reach an internal app is decided here, from the RBEC, with git as the audit
# log. Auth happens via your IdP at sign-in; no Cloudflare credentials are
# created or stored for users.

resource "cloudflare_zero_trust_access_group" "group" {
  for_each   = var.enable_cloudflare ? local.cloudflare_groups : {}
  account_id = var.cloudflare_account_id
  name       = each.key

  include {
    email = each.value
  }
}

# Dashboard membership: roles that declare cloud.cloudflare.dashboardRole get
# their holders invited to the Cloudflare account (Cloudflare sends the email).
data "cloudflare_account_roles" "all" {
  count      = var.enable_cloudflare ? 1 : 0
  account_id = var.cloudflare_account_id
}

locals {
  # role name -> role id, resolved live from the account
  cloudflare_role_ids = var.enable_cloudflare ? {
    for r in data.cloudflare_account_roles.all[0].roles : r.name => r.id
  } : {}
}

resource "cloudflare_account_member" "member" {
  for_each      = var.enable_cloudflare ? local.cloudflare_members : {}
  account_id    = var.cloudflare_account_id
  email_address = each.key
  role_ids      = [local.cloudflare_role_ids[each.value]]

  lifecycle {
    precondition {
      condition     = contains(keys(local.cloudflare_role_ids), each.value)
      error_message = "Role declares Cloudflare dashboardRole '${each.value}', which does not exist on this account. Valid: ${join(", ", keys(local.cloudflare_role_ids))}."
    }
  }
}
