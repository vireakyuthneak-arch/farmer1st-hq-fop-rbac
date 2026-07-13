#!/bin/bash
# cf-onboard.sh — run the Cloudflare slice of RBEC onboarding from a local .env.
#
# Loads credentials from .env (repo root, gitignored, chmod 600), validates the
# RBEC, then plans/applies ONLY the Cloudflare resources (-target), so missing
# AWS/GitHub credentials never block a Cloudflare run.
#
# Usage:
#   bash scripts/cf-onboard.sh          # plan (safe — shows changes, applies nothing)
#   bash scripts/cf-onboard.sh apply    # actually create groups + send invites
#
# .env keys (see .env.example):
#   CLOUDFLARE_API_TOKEN     required — scoped token (Members Edit, Access Edit, Account Read)
#   CLOUDFLARE_ACCOUNT_ID    required — becomes TF_VAR_cloudflare_account_id
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
ACTION="${1:-plan}"

case "$ACTION" in plan|apply) ;; *) echo "usage: cf-onboard.sh [plan|apply]" >&2; exit 2 ;; esac

# --- load .env safely ---
if [ ! -f "$ENV_FILE" ]; then
  echo "No .env found at $ENV_FILE" >&2
  echo "Create one from the template:  cp .env.example .env  (then fill it in)" >&2
  exit 1
fi
# Tokens are secrets: keep the file owner-read-only.
perms="$(stat -f '%Lp' "$ENV_FILE")"
if [ "$perms" != "600" ]; then
  chmod 600 "$ENV_FILE"
  echo "note: tightened .env permissions to 600 (was $perms)"
fi
set -a; . "$ENV_FILE"; set +a

[ -n "${CLOUDFLARE_API_TOKEN:-}" ]  || { echo "CLOUDFLARE_API_TOKEN missing from .env" >&2; exit 1; }
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || { echo "CLOUDFLARE_ACCOUNT_ID missing from .env" >&2; exit 1; }
export TF_VAR_cloudflare_account_id="$CLOUDFLARE_ACCOUNT_ID"

# --- split-brain guard: once HCP Terraform owns the workspace (cloud block
# active in versions.tf), local applies would run against SEPARATE state and
# double-create resources. Use the HCP dashboard from that point on. ---
if grep -qE '^[[:space:]]*cloud[[:space:]]*\{' "$ROOT/terraform/versions.tf"; then
  echo "HCP Terraform is active for this repo (cloud block in versions.tf)." >&2
  echo "Run plans/applies from app.terraform.io instead of this script." >&2
  exit 1
fi

# --- validate the RBEC first (never plan a broken spec) ---
"$ROOT/.venv/bin/python" "$ROOT/scripts/validate.py" validate

# --- terraform, Cloudflare resources only ---
TARGETS=(-target=cloudflare_zero_trust_access_group.group -target=cloudflare_account_member.member)

terraform -chdir="$ROOT/terraform" init -input=false -upgrade=false >/dev/null
terraform -chdir="$ROOT/terraform" validate >/dev/null

if [ "$ACTION" = "plan" ]; then
  terraform -chdir="$ROOT/terraform" plan -input=false "${TARGETS[@]}"
  echo
  echo "That was a dry run. To make it real:  bash scripts/cf-onboard.sh apply"
else
  terraform -chdir="$ROOT/terraform" apply -input=false "${TARGETS[@]}"
fi
