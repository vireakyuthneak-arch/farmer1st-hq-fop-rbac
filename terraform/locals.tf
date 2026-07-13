# Read the SAME FOP spec Abra consumes, straight from the yml files. Terraform
# and Abra share one source of truth: roles declare access, users bind identity.
#
# Fail-closed by construction:
#   - an unknown role name in a user file is a HARD plan error (local.user_roles
#     indexes local.roles directly — no try() around the role lookup), never a
#     silent resolve-to-nothing that would plan mass revocation;
#   - an empty/missing profiles/users or profiles/roles directory aborts the plan via
#     local.spec_guard instead of planning destruction of all managed access.
#
# Stable resource keys: derived maps are keyed by identity (github handle,
# SSO username/email), NOT by yml filename — renaming a file must never
# destroy/recreate someone's org membership or account assignments.
# (scripts/validate.py additionally enforces filename == user:/role: field.)
locals {
  roles_dir = "${path.module}/../profiles/roles"
  users_dir = "${path.module}/../profiles/users"

  roles = {
    for f in fileset(local.roles_dir, "*.yml") :
    trimsuffix(f, ".yml") => yamldecode(file("${local.roles_dir}/${f}"))
  }
  users = {
    for f in fileset(local.users_dir, "*.yml") :
    trimsuffix(f, ".yml") => yamldecode(file("${local.users_dir}/${f}"))
  }

  # Guard: a broken checkout / renamed directory yields empty filesets, which
  # would otherwise plan a clean-looking destruction of everything managed.
  spec_guard = (length(local.roles) > 0 && length(local.users) > 0) ? true : tobool(
    "RBEC spec error: profiles/roles or profiles/users resolved to zero files — refusing to plan (this would revoke all managed access). Check the repo layout / working directory."
  )

  # Resolve every user's role list ONCE, with a direct index: an unknown role
  # name fails the plan here with an 'Invalid index' pointing at the bad name.
  # (the `if local.spec_guard` clause forces the guard to evaluate — it errors
  # via tobool() on a broken spec, and filters nothing when healthy)
  user_roles = {
    for uname, u in local.users :
    uname => [for r in u.roles : local.roles[r]] if local.spec_guard
  }

  # (github handle, team) memberships — union of teams across a user's roles.
  # Keyed by the handle, so file renames don't churn resources. Users whose
  # roles grant no teams never need a github handle at all.
  # Gated: while enable_github=false this stays empty so users whose logins
  # aren't collected yet don't fail the plan; flipping the gate with a missing
  # identity.github is a HARD error (fail-closed at grant time).
  github_memberships = !var.enable_github ? {} : merge([
    for uname, u in local.users : {
      for team in distinct(flatten([
        for role in local.user_roles[uname] : try(role.cloud.github.teams, [])
      ])) :
      "${u.identity.github}:${team}" => {
        github_user = u.identity.github
        team        = team
      }
      } if length(flatten([
        for role in local.user_roles[uname] : try(role.cloud.github.teams, [])
    ])) > 0
  ]...)

  # Distinct github handles that hold >=1 team (drives org membership).
  github_org_members = toset([for m in local.github_memberships : m.github_user])

  github_teams = toset([for m in local.github_memberships : m.team])

  # (SSO user x account x permission-set) AWS assignments — union of every
  # cloud.aws.grants entry across a user's roles, deduplicated. Keyed by SSO
  # username (email), stable across file renames.
  aws_assignments = merge([
    for uname, u in local.users : {
      for g in distinct(flatten([
        for role in local.user_roles[uname] : try(role.cloud.aws.grants, [])
      ])) :
      "${try(u.identity.awsUserName, u.identity.email)}:${g.account}:${g.permissionSet}" => {
        # SSO username defaults to the work email; set identity.awsUserName
        # in a user file only when they differ.
        aws_user       = try(u.identity.awsUserName, u.identity.email)
        account        = g.account
        permission_set = g.permissionSet
      }
    }
  ]...)

  # Identity Center users to CREATE: one per user that holds >=1 AWS grant.
  aws_identities = {
    for uname, u in local.users :
    try(u.identity.awsUserName, u.identity.email) => {
      email     = u.identity.email
      full_name = try(u.identity.fullName, u.identity.email)
      } if length(flatten([
        for role in local.user_roles[uname] : try(role.cloud.aws.grants, [])
    ])) > 0
  }

  # Cloudflare dashboard members: email -> account role name, for users whose
  # role declares cloud.cloudflare.dashboardRole (first such role wins).
  cloudflare_members = {
    for uname, u in local.users :
    u.identity.email => compact([
      for role in local.user_roles[uname] : try(role.cloud.cloudflare.dashboardRole, "")
    ])[0]
    if length(compact([
      for role in local.user_roles[uname] : try(role.cloud.cloudflare.dashboardRole, "")
    ])) > 0
  }

  # Cloudflare Zero Trust Access groups: group name -> member emails, unioned
  # across every user's roles.
  cloudflare_groups = {
    for g in distinct(flatten([
      for uname, u in local.users : flatten([
        for role in local.user_roles[uname] : try(role.cloud.cloudflare.accessGroups, [])
      ])
    ])) :
    g => sort(distinct([
      for uname, u in local.users : u.identity.email
      if contains(flatten([
        for role in local.user_roles[uname] : try(role.cloud.cloudflare.accessGroups, [])
      ]), g)
    ]))
  }
}
