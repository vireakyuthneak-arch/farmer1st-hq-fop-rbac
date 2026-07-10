# GitHub access, derived from FOP roles.
#
# GATED behind var.enable_github (default false): flip it on once the org
# token (GITHUB_TOKEN) is configured and the teams exist in the org.
#
# Every assigned user is an org member; then each (user, team) pair from their
# roles becomes a team membership. Remove a team from a role, or a role from a
# user, and Terraform revokes the membership on the next apply.

resource "github_membership" "org" {
  for_each = var.enable_github ? { for uname, u in local.users : uname => u.identity.github } : {}
  username = each.value
  role     = "member"
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
}
