# GitHub access, derived from FOP roles.
#
# Every assigned user is an org member; then each (user, team) pair from their
# roles becomes a team membership. Remove a team from a role, or a role from a
# user, and Terraform revokes the membership on the next apply.

resource "github_membership" "org" {
  for_each = { for uname, u in local.users : uname => u.identity.github }
  username = each.value
  role     = "member"
}

data "github_team" "team" {
  for_each = local.github_teams
  slug     = each.value
}

resource "github_team_membership" "member" {
  for_each = local.github_memberships
  team_id  = data.github_team.team[each.value.team].id
  username = each.value.github_user
  role     = "member"
}
