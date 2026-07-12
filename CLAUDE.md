# FOP — project guide

FOP (Farmer1st Operating Platform) is the **single source of truth**, in plain
YAML, for what each employee's Mac and cloud access should be. The spec is called
the **RBEC — Role-Based Entitlement Contract** (the files under `fop/`).
It is consumed by two things:

1. **Abra** — a background binary on each Mac (**built separately, NOT in this
   repo**). It runs on a system heartbeat, reads this spec, resolves the logged-in
   user's role to an app set, and installs/updates/reaps apps via Homebrew.
2. **Terraform** (`terraform/`, in this repo) — reads the *same* spec during
   onboarding and provisions the user's GitHub + AWS access.

One spec, two consumers. This repo owns the **spec and the Terraform** — not Abra.

## Layout

| Path | What |
|------|------|
| `fop/catalog.yml` | Every app defined once, keyed. `source` ∈ `formula`/`cask` (Homebrew), `mas` (Mac App Store), `direct` (signed https download, needs `sha256`). |
| `fop/roles/*.yml` | One per role: `apps` (catalog keys) + `cloud` access (aws `grants[]` of account × permissionSet, github org/teams, cloudflare accessGroups/dashboardRole). |
| `fop/users/*.yml` | One per person: `identity` + `devices` + `roles` + `overrides` (add/remove apps). |
| `schema/*.schema.json` | JSON Schema contract Abra + CI validate against. |
| `docs/ABRA-CONTRACT.md` | The full Abra ↔ RBEC interface spec (what Abra reads and how it must converge). |
| `scripts/validate.py` | `validate` (schema + cross-refs) and `resolve <user>` (prints the exact app set Abra installs). |
| `terraform/` | Reads `fop/` via `yamldecode`. Two AWS layers: `aws-foundation.tf` (the permission-set **catalog as code**: ReadOnly/Developer/DevOpsEngineer/BreakGlassAdmin) + `aws.tf` (Identity Center users + assignments). Also `github.tf` (org+team membership), `cloudflare.tf` (Access groups + dashboard members), `variables.tf` (account IDs, `enable_aws`/`enable_github` gates). |

## Commands

```bash
make setup                     # one-time: Python venv (pyyaml, jsonschema)
make validate                  # what CI should run
make resolve USER=vireakyuth   # resolved desired app set for a user
make tf-validate               # terraform init + validate
make tf-plan                   # show GitHub/AWS access the spec resolves to (no cloud creds)
```

## Conventions

- Add an **app**: one entry in `fop/catalog.yml`, then reference its key in a role.
- Add a **role**: new `fop/roles/<role>.yml`. Add a **person**: new
  `fop/users/<user>.yml`. Run `make validate` after any change.
- Keys are lowercase kebab-case. Every role app and every user override must
  reference a real catalog key; every user role must reference a real role file —
  `validate` enforces this.
- After edits, run `make validate`; for terraform edits, `make tf-fmt` then
  `make tf-validate`.

## Guardrails (important)

- **No secrets in the spec.** FOP declares *what access* a role gets; Terraform
  *realizes* it via AWS SSO, and users get short-lived creds through
  `aws sso login`. Real account IDs live in `terraform/variables.tf`
  (`var.account_ids`); permission sets are **defined as code** in
  `terraform/aws-foundation.tf` and referenced by name from roles — never
  secrets in git. Keep it that way — the spec is meant to be broadly readable
  and auditable via git history.
- **Do not build Abra here.** It is a separate project. This repo stops at the
  spec + Terraform. (An earlier throwaway Go prototype of Abra was intentionally
  deleted — do not resurrect it.)
- Not to be confused with the **GFNet** product platform (a different repo).

## Open items

- Spec named **RBEC** (Role-Based Entitlement Contract); "ABEC" was a
  typo of the same thing. The `fop/` directory can be renamed `dbec/` if wanted.
- Terraform currently *assumes* the GitHub teams already exist (`github.tf`
  data-looks them up); creating them from the spec is a possible next step.
  SSO permission sets are NOT assumed — they are created by
  `terraform/aws-foundation.tf`; do not pre-create sets with the same names in
  the console (name collision on apply).
- AWS and GitHub are gated (`enable_aws` / `enable_github`, default false)
  until their credentials + real account values exist; Cloudflare is live first.
