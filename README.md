# FOP — Farmer1st Operating Platform (spec + onboarding IaC)

FOP is the **single source of truth** for what each employee's Mac and cloud
access should be. The spec itself is called the **RBEC — Device Baseline &
Entitlement Contract**: the YAML that declares each role's baseline apps and its
entitlements. It is plain YAML in git. Two consumers read the RBEC:

1. **Abra** (the background binary on each Mac — built separately) reads the spec,
   figures out which apps the logged-in user's role needs, and installs/updates/
   removes them on a system heartbeat.
2. **Terraform** (here) reads the *same* spec during onboarding and provisions the
   user's GitHub and AWS access.

One spec, two consumers. Change a role once and both the Mac fleet and cloud
access follow.

```
                    ┌───────────────────────────┐
                    │  FOP spec (this repo, YAML) │
                    │  catalog · roles · users    │
                    └───────────┬─────────┬───────┘
                       reads     │         │   reads
                 ┌───────────────┘         └───────────────┐
                 ▼                                          ▼
        Abra (on each Mac)                        Terraform (onboarding)
   resolve user → app set →                 roles → GitHub teams + AWS SSO
   brew install / update / reap                 permission-set assignments
```

> **Building or integrating Abra?** The complete Abra ↔ RBEC interface — what
> Abra must read, how to resolve a device to an app set, install semantics per
> source, convergence rules — is specified in
> [`docs/ABRA-CONTRACT.md`](docs/ABRA-CONTRACT.md).

## The spec (RBEC)

| File | What it is |
|------|-----------|
| [`fop/catalog.yml`](fop/catalog.yml) | Every installable app, defined once, keyed. Says **how** to fetch each (Homebrew formula/cask, Mac App Store, or a signed direct download). |
| [`fop/roles/*.yml`](fop/roles) | One file per role (e.g. `devops-engineer`). Lists apps by catalog key + the cloud/GitHub **access** the role grants. |
| [`fop/users/*.yml`](fop/users) | One file per person. Binds identity (email, GitHub, AWS username) + device serials + assigned role(s) + per-user app overrides. |
| [`schema/*.schema.json`](schema) | JSON Schemas — the formal contract Abra and CI validate against. |

### How an app is described (catalog)

```yaml
apps:
  vscode:      { name: Visual Studio Code, source: cask,    id: visual-studio-code }
  python:      { name: Python 3.12,        source: formula, id: python@3.12, version: "3.12" }
  xcode:       { name: Xcode,              source: mas,     id: "497799835" }
```

`source` tells Abra where to get it: `formula`/`cask` (Homebrew), `mas` (Mac App
Store), or `direct` (a signed `.pkg`/`.dmg` over https, with a required `sha256`).

### How a role is described

```yaml
role: devops-engineer
apps: [vscode, slack, granola, docker, docker-compose, docker-desktop, python, awscli, terraform, kubectl]
cloud:
  aws:    { account: farmer1st-dev, permissionSet: DevOpsEngineer }
  github: { org: farmer1st-hq, teams: [devops, infrastructure] }
```

### How a person is assigned

```yaml
user: vireakyuth
identity: { email: vireakyuth.neak@farmer1st.org, github: vireakyuth, awsUserName: vireakyuth.neak@farmer1st.org }
devices:  [{ serial: C02XX1234567, hostname: vireakyuth-mac }]
roles:    [devops-engineer]
overrides: { add: [postman], remove: [] }     # tweak without forking a role
```

## Try it

```bash
make setup                      # one-time: Python venv for the validator
make validate                   # schema + cross-reference check (what CI runs)
make resolve USER=vireakyuth    # print the exact app set Abra would install
make tf-validate                # terraform init + validate
make tf-plan                    # show the GitHub/AWS access the spec resolves to
```

`make resolve USER=vireakyuth` prints, e.g.:

```
  awscli           formula  awscli
  docker           formula  docker
  ...
  python           formula  python@3.12 @3.12
  vscode           cask     visual-studio-code
```

That resolved list — role apps, plus `overrides.add`, minus `overrides.remove` —
is precisely the desired state Abra converges the Mac to.

## Onboarding with Terraform

[`terraform/`](terraform) reads `fop/roles` and `fop/users` directly with
`yamldecode`, then for each user provisions:

- **AWS** — **creates their IAM Identity Center (SSO) user** and assigns each
  role's permission set on its account ([`aws.tf`](terraform/aws.tf)). The user
  then runs `aws sso login` and receives short-lived tokens — no access keys
  are ever generated or stored.
- **GitHub** — org membership invitation + a team membership for every team
  across their roles ([`github.tf`](terraform/github.tf)). (GitHub *accounts*
  cannot be created by API — people bring their own; the invite is automatic.)
- **Cloudflare** — Zero Trust Access group membership per role
  ([`cloudflare.tf`](terraform/cloudflare.tf)); Access policies on internal
  apps reference these groups.

Add a team to a role, or a role to a user, and the next `terraform apply` grants
it; remove it and Terraform revokes it. Same GitOps model as the app side.

### CI: merge-to-main is the onboarding button

[`.github/workflows/onboarding.yml`](.github/workflows/onboarding.yml) runs
`make validate` + `terraform plan` on every PR that touches `fop/` or
`terraform/`, and `terraform apply` on merge to `main`. The PR review is the
approval gate; git history is the audit log.

### Master credentials (what Terraform itself authenticates with)

Never stored in this repo. Local runs use env vars; CI uses Actions secrets +
OIDC:

| Provider | Local run | CI (GitHub Actions) | Scope to grant |
|----------|-----------|---------------------|----------------|
| AWS | your own `aws sso login` (admin profile) | **OIDC federation** — Actions assumes an IAM role (`AWS_TERRAFORM_ROLE_ARN` repo variable); **no static key exists** | `sso-admin` + `identitystore` write on the management account |
| GitHub | `GITHUB_TOKEN` env var | `GH_ORG_TOKEN` secret | fine-grained org token (or GitHub App): org members + team members read/write |
| Cloudflare | `CLOUDFLARE_API_TOKEN` env var | `CLOUDFLARE_API_TOKEN` secret | API token scoped to Access: apps/groups edit (never the Global API Key) |

> ### Why no raw credentials in the spec
> FOP declares **what access** a role should have, never secrets. Terraform
> *realizes* that access: it assigns the user's SSO principal to a permission
> set, and the user gets short-lived credentials via `aws sso login`. Real
> account IDs and permission-set ARNs live in Terraform variables
> ([`variables.tf`](terraform/variables.tf)), not in git as secrets. This keeps
> the spec safe to be broadly readable and auditable via git history.

## Adding things

- **New app** → add one entry to `fop/catalog.yml`, then list its key in a role.
- **New role** → add `fop/roles/<role>.yml`; `make validate`.
- **New hire** → add `fop/users/<user>.yml` with their identity, device, and role;
  `make validate`, then `terraform apply` to grant cloud/GitHub access. Abra picks
  up the apps on the Mac's next heartbeat.
