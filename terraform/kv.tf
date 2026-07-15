# ===========================================================================
# App RBAC materialization — the fop-rbac Cloudflare KV namespace.
#
# On every apply, the resolved per-user application roles (locals.tf:
# local.app_rbac_docs) are written as one KV document per user, key
# `user:<lowercased-email>`. Internal Cloudflare Worker apps bind this
# namespace READ-ONLY and authorize from apps.<their-id>.role — the consumer
# contract (fail-closed rules, caching bounds) is docs/APP-RBAC.md.
#
# Terraform-managed on purpose: offboarding/email changes DELETE keys via
# state (a CI pusher would leave ghost access), drift from rogue writes is
# reverted on the next apply, and HCP plan diffs show every access change
# per email before merge.
#
# Writes ride the dedicated KV-only token (provider alias "kv") — Workers KV
# Storage: Edit is account-wide, so it stays off the Access/members token.
# ===========================================================================

resource "cloudflare_workers_kv_namespace" "fop_rbac" {
  count      = var.enable_cloudflare ? 1 : 0
  provider   = cloudflare.kv
  account_id = var.cloudflare_account_id
  title      = "fop-rbac"

  # Recreating the namespace changes its ID and breaks every app's binding
  # (fleet-wide authZ outage — fail-closed apps deny everyone). Deliberate,
  # coordinated event only.
  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_workers_kv" "user_doc" {
  for_each     = var.enable_cloudflare ? local.app_rbac_docs : {}
  provider     = cloudflare.kv
  account_id   = var.cloudflare_account_id
  namespace_id = cloudflare_workers_kv_namespace.fop_rbac[0].id
  key          = each.key
  value        = each.value
}
