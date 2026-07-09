# Read the SAME FOP spec Abra consumes, straight from the yml files. Terraform
# and Abra share one source of truth: roles declare access, users bind identity.
locals {
  roles_dir = "${path.module}/../fop/roles"
  users_dir = "${path.module}/../fop/users"

  roles = {
    for f in fileset(local.roles_dir, "*.yml") :
    trimsuffix(f, ".yml") => yamldecode(file("${local.roles_dir}/${f}"))
  }
  users = {
    for f in fileset(local.users_dir, "*.yml") :
    trimsuffix(f, ".yml") => yamldecode(file("${local.users_dir}/${f}"))
  }

  # (user, team) memberships — the union of GitHub teams across a user's roles.
  github_memberships = merge([
    for uname, u in local.users : {
      for team in distinct(flatten([
        for r in u.roles : try(local.roles[r].cloud.github.teams, [])
      ])) :
      "${uname}:${team}" => {
        github_user = u.identity.github
        team        = team
      }
    }
  ]...)

  # (user, role) AWS assignments — each maps to an account + permission set.
  aws_assignments = merge([
    for uname, u in local.users : {
      for r in u.roles :
      "${uname}:${r}" => {
        # SSO username defaults to the work email; set identity.awsUserName
        # in a user file only when they differ.
        aws_user       = try(u.identity.awsUserName, u.identity.email)
        account        = local.roles[r].cloud.aws.account
        permission_set = local.roles[r].cloud.aws.permissionSet
      } if try(local.roles[r].cloud.aws, null) != null
    }
  ]...)

  # Identity Center users to CREATE: one per user that holds >=1 AWS-bearing
  # role. Keyed by SSO username (email unless identity.awsUserName overrides).
  aws_identities = {
    for uname, u in local.users :
    try(u.identity.awsUserName, u.identity.email) => {
      email     = u.identity.email
      full_name = try(u.identity.fullName, u.identity.email)
    } if length([for r in u.roles : r if try(local.roles[r].cloud.aws, null) != null]) > 0
  }

  github_teams = toset([for m in local.github_memberships : m.team])

  # Cloudflare dashboard members: email -> account role name, for users whose
  # role declares cloud.cloudflare.dashboardRole (first such role wins).
  cloudflare_members = {
    for uname, u in local.users :
    u.identity.email => compact([for r in u.roles : try(local.roles[r].cloud.cloudflare.dashboardRole, "")])[0]
    if length(compact([for r in u.roles : try(local.roles[r].cloud.cloudflare.dashboardRole, "")])) > 0
  }

  # Cloudflare Zero Trust Access groups: group name -> member emails, unioned
  # across every user's roles.
  cloudflare_groups = {
    for g in distinct(flatten([
      for uname, u in local.users : flatten([
        for r in u.roles : try(local.roles[r].cloud.cloudflare.accessGroups, [])
      ])
    ])) :
    g => sort(distinct([
      for uname, u in local.users : u.identity.email
      if contains(flatten([
        for r in u.roles : try(local.roles[r].cloud.cloudflare.accessGroups, [])
      ]), g)
    ]))
  }
}
