# Cloudflare access, derived from FOP roles, via Zero Trust Access groups.
#
# Each role lists cloud.cloudflare.accessGroups; Terraform materializes every
# group with its member emails (unioned across users' roles). Access policies
# on protected apps / WARP then reference these groups by name — so who can
# reach an internal app is decided here, from the RBEC, with git as the audit
# log. Auth happens via your IdP at sign-in; no Cloudflare credentials are
# created or stored for users.

resource "cloudflare_zero_trust_access_group" "group" {
  for_each   = local.cloudflare_groups
  account_id = var.cloudflare_account_id
  name       = each.key

  include {
    email = each.value
  }
}

# Dashboard membership: roles that declare cloud.cloudflare.dashboardRole get
# their holders invited to the Cloudflare account (Cloudflare sends the email).
data "cloudflare_account_roles" "all" {
  account_id = var.cloudflare_account_id
}

locals {
  # role name -> role id, resolved live from the account
  cloudflare_role_ids = {
    for r in data.cloudflare_account_roles.all.roles : r.name => r.id
  }
}

resource "cloudflare_account_member" "member" {
  for_each      = local.cloudflare_members
  account_id    = var.cloudflare_account_id
  email_address = each.key
  role_ids      = [local.cloudflare_role_ids[each.value]]
}
