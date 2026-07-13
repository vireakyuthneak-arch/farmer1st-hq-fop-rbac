# GitHub access, derived from FOP roles.
#
# GATED behind var.enable_github (default false): flip it on once the org
# token (GITHUB_TOKEN) is configured and the teams exist in the org.
#
# Org membership is granted ONLY to users whose roles carry >=1 GitHub team —
# users without GitHub-bearing roles (e.g. a cloudflare-only admin) need no
# github handle and are never invited. Resources are keyed by the github
# handle, so renaming a user's yml file never destroys their membership.
# Remove a team from a role, or a role from a user, and Terraform revokes the
# membership on the next apply.

resource "github_membership" "org" {
  for_each = var.enable_github ? local.github_org_members : toset([])
  username = each.value
  # Org owners must be listed in var.github_org_admins — otherwise Terraform
  # would DOWNGRADE an owner to plain member on apply.
  role = contains(var.github_org_admins, each.value) ? "admin" : "member"
}

data "github_team" "team" {
  for_each = var.enable_github ? local.github_teams : toset([])
  slug     = each.value
}

resource "github_team_membership" "member" {
  for_each = var.enable_github ? local.github_memberships : {}
  team_id  = data.github_team.team[each.value.team].id
  username = each.value.github_user
  role     = "member"

  depends_on = [github_membership.org]
}
