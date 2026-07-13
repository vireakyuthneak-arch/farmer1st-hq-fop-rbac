# FOP — project guide

FOP (Farmer1st Operating Platform) is the **single source of truth**, in plain
YAML, for what each employee's Mac and cloud access should be. Spec vocabulary
(use these terms, not the retired RBEC/DBEC/ABEC nicknames): **Profiles** (the
config under `profiles/`), **Rendered Manifest** (CI output the daemon
consumes), **Whitelist**, **Managed Set**. Consumers:

1. **The FOP daemon (Abra)** — built separately, NOT in this repo, and it
   **never reads this repo**: `render/render.py` renders Profiles into hashed
   manifests; CI dispatches them to `fop-appstore`; the daemon fast-polls the
   appstore and applies. See docs/ABRA-CONTRACT.md (hash recipe + golden
   fixture — never break it).
2. **Terraform** (`terraform/`, this repo) — reads the same Profiles and
   provisions AWS / GitHub / Cloudflare access.

This repo owns the **Profiles, the renderer, and the Terraform** — not the daemon.

## Layout

| Path | What |
|------|------|
| `profiles/catalog.yml` | Every app defined once, keyed. `source` ∈ `formula`/`cask` ONLY (ADR-0020) — App Store/direct apps are MDM/VPP territory. |
| `profiles/roles/*.yml` | One per role: `apps` (catalog keys) + `cloud` access (aws `grants[]` of account × permissionSet, github org/teams, cloudflare accessGroups/dashboardRole). |
| `profiles/users/*.yml` | One per person, keyed by GitHub login (filename == `user:` == login): `identity` + `roles` + `overrides`. |
| `profiles/devices.yml` | Serial → user map (the daemon's device lookup). |
| `render/` | Deterministic renderer + golden-fixture tests → Rendered Manifests for fop-appstore. |
| `schema/*.schema.json` | JSON Schema contract Abra + CI validate against. |
| `docs/ABRA-CONTRACT.md` | The full Abra ↔ RBEC interface spec (what Abra reads and how it must converge). |
| `scripts/validate.py` | `validate` (schema + cross-refs) and `resolve <user>` (prints the exact app set Abra installs). |
| `terraform/` | Reads `profiles/` via `yamldecode`. Two AWS layers: `aws-foundation.tf` (the permission-set **catalog as code**: ReadOnly/Developer/DevOpsEngineer/BreakGlassAdmin) + `aws.tf` (Identity Center users + assignments). Also `github.tf` (org+team membership), `cloudflare.tf` (Access groups + dashboard members), `variables.tf` (account IDs, `enable_aws`/`enable_github` gates). |

## Commands

```bash
make setup                     # one-time: Python venv (pyyaml, jsonschema)
make validate                  # what CI should run
make resolve USER=vireakyuth   # resolved desired app set for a user
make tf-validate               # terraform init + validate
make tf-plan                   # show GitHub/AWS access the spec resolves to (no cloud creds)
```

## Conventions

- Add an **app**: one entry in `profiles/catalog.yml`, then reference its key in a role.
- Add a **role**: new `profiles/roles/<role>.yml`. Add a **person**: new
  `profiles/users/<user>.yml`. Run `make validate` after any change.
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

- 9 of 10 fleet users still need their real **GitHub login** filled in
  (`identity.github`, and rename file+`user:`+devices.yml entry to match).
  Blocking for `enable_github`, not for app delivery.
- Terraform currently *assumes* the GitHub teams already exist (`github.tf`
  data-looks them up); creating them from the spec is a possible next step.
  SSO permission sets are NOT assumed — they are created by
  `terraform/aws-foundation.tf`; do not pre-create sets with the same names in
  the console (name collision on apply).
- AWS and GitHub are gated (`enable_aws` / `enable_github`, default false)
  until their credentials + real account values exist; Cloudflare is live first.
