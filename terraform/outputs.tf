# Plan-time visibility: what access the FOP spec resolves to, before apply.

output "github_memberships" {
  description = "Every (user -> team) membership derived from FOP roles."
  value = {
    for k, m in local.github_memberships : k => "${m.github_user} -> ${m.team}"
  }
  sensitive = true
}

output "aws_assignments" {
  description = "Every (user -> account/permission-set) assignment derived from FOP roles."
  value = {
    for k, a in local.aws_assignments : k => "${a.aws_user} -> ${a.account}/${a.permission_set}"
  }
  sensitive = true
}

output "cloudflare_groups" {
  description = "Every Zero Trust Access group and its members, derived from FOP roles."
  value       = local.cloudflare_groups
  sensitive   = true
}
