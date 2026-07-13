# FOP — Farmer1st Operating Platform (spec + onboarding IaC)

FOP is the **single source of truth** for what each employee's Mac and cloud
access should be. The config here is the **Profiles** tree (spec term;
formerly nicknamed "RBEC"): plain YAML declaring the app catalog, role
profiles, users, and the device map. Two consumers:

1. **The FOP daemon (Abra)** on each Mac — it never reads this repo. CI
   **renders** the Profiles into hashed **Rendered Manifests**, publishes them
   to `fop-appstore` (via `repository_dispatch` — this repo holds no appstore
   credential), and the daemon fast-polls the appstore (ETag) and applies.
2. **Terraform** (here) reads the same Profiles during onboarding and
   provisions the user's AWS / GitHub / Cloudflare access.

```
 profiles/ (this repo)                     Terraform (this repo)
     │  render/render.py                        roles → AWS SSO grants +
     ▼                                          GitHub teams + Cloudflare groups
 manifests/*.json ──dispatch──▶ fop-appstore
                                     ▲
                     ETag fast-poll  │
                            fop daemon (each Mac): brew bundle · reap
```

> **Integrating with the daemon?** The manifest schema, the byte-exact
> `payload_sha256` recipe, and the golden fixture are in
> [`docs/ABRA-CONTRACT.md`](docs/ABRA-CONTRACT.md).

## The spec (Profiles)

| File | What it is |
|------|-----------|
| [`profiles/catalog.yml`](profiles/catalog.yml) | Every installable app, defined once, keyed. Homebrew **formulae + public casks only** (ADR-0020) — App Store / direct-download apps are out of FOP scope (MDM/VPP). |
| [`profiles/roles/*.yml`](profiles/roles) | One file per role. Apps by catalog key + `system[]` (trust-plane installs) + `whitelist[]` (tolerated self-installs) + the cloud **access** the role grants. |
| [`profiles/users/*.yml`](profiles/users) | One file per person, **keyed by GitHub login** (filename == `user:` == login). Identity + role(s) + overrides. No device serials here. |
| [`profiles/devices.yml`](profiles/devices.yml) | The device map: Mac serial → user key. Rendered into `manifests/index.json` for the daemon's lookup. |
| [`render/`](render) | The deterministic renderer + golden-fixture tests — produces the daemon's Rendered Manifests. |
| [`schema/*.schema.json`](schema) | JSON Schemas — the formal contract CI validates against. |

### How an app is described (catalog)

```yaml
apps:
  vscode:      { name: Visual Studio Code, source: cask,    id: visual-studio-code, version: latest }
  python:      { name: Python 3.12,        source: formula, id: python@3.12, version: "3.12" }
```

`source` is `formula` or `cask` — Homebrew only (ADR-0020). App Store apps
(iWork, Xcode, Trello…) are delivered by MDM/VPP, outside FOP.

### How a role is described

```yaml
role: devops-engineer
apps: [vscode, slack, granola, docker, docker-compose, docker-desktop, python, awscli, terraform, kubectl]
cloud:
  aws:
    grants: # account x permission set, any number of pairs
      - { account: farmer1st-dev, permissionSet: DevOpsEngineer }
      - { account: farmer1st-prod, permissionSet: Developer }
  github: { org: farmer1st-hq, teams: [devops, infrastructure] }
  cloudflare: { accessGroups: [internal-dashboards, infra-admin] }
```

Permission-set names come from the small catalog defined as code in
[`terraform/aws-foundation.tf`](terraform/aws-foundation.tf) (ReadOnly ·
Developer · DevOpsEngineer · BreakGlassAdmin); logical account names resolve to
real ids via `var.account_ids`.

### How a person is assigned

```yaml
# profiles/users/vireakyuth.yml — filename == user == GitHub login
user: vireakyuth
identity: { email: vireakyuth.neak@farmer1st.org, github: vireakyuth }
roles:    [backend-engineer, devops-engineer]
overrides: { add: [figma] }        # optional tweak without forking a role
```

Device serials live in [`profiles/devices.yml`](profiles/devices.yml)
(`serial: user`), one line per enrolled Mac.

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

[`terraform/`](terraform) reads `profiles/roles` and `profiles/users` directly with
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

### CI: merge-to-main is the onboarding button (via HCP Terraform)

Two systems split the work:

- **GitHub Actions** ([`validate` workflow](.github/workflows/onboarding.yml))
  validates the Profiles (schemas + cross-references) on every PR and push.
- **HCP Terraform** (app.terraform.io, VCS-driven workspace on this repo,
  working directory `terraform/`) posts a speculative plan on every PR and
  applies on merge to `main`. State lives in the workspace; every run is
  logged and (with manual apply) explicitly confirmed.

Workspace setup checklist:
1. app.terraform.io -> create org -> New workspace -> Version control workflow
   -> pick this repo.
2. Settings: Terraform Working Directory = `terraform`; VCS triggers limited to
   `terraform/` and `profiles/`; apply method = Manual (recommended to start).
3. Variables: `cloudflare_account_id` (Terraform variable) +
   `CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN` (env vars, mark Sensitive). AWS:
   dynamic provider credentials (`TFC_AWS_PROVIDER_AUTH=true`,
   `TFC_AWS_RUN_ROLE_ARN=...`) when the AWS side goes live.
4. Uncomment the `cloud {}` block in [`versions.tf`](terraform/versions.tf)
   with the org/workspace names, commit, push.

### Master credentials (what Terraform itself authenticates with)

Never stored in this repo. Local runs use `.env` / env vars; HCP Terraform uses
workspace variables:

| Provider | Local run | HCP Terraform workspace | Scope to grant |
|----------|-----------|-------------------------|----------------|
| AWS | your own `aws sso login` (admin profile) | dynamic provider credentials (OIDC role) — **no static key exists** | `sso-admin` + `identitystore` write on the management account |
| GitHub | `GITHUB_TOKEN` env var | `GITHUB_TOKEN` env var (Sensitive) | fine-grained org token (or GitHub App): org members + team members read/write |
| Cloudflare | `.env` via [`scripts/cf-onboard.sh`](scripts/cf-onboard.sh) | `CLOUDFLARE_API_TOKEN` env var (Sensitive) | API token: Members edit + Access groups edit + account read (never the Global API Key) |

## Adding things

- **New app** → add one entry to `profiles/catalog.yml`, then list its key in a role.
- **New role** → add `profiles/roles/<role>.yml`; `make validate`.
- **New hire** → add `profiles/users/<user>.yml` with their identity, device, and role;
  `make validate`, then `terraform apply` to grant cloud/GitHub access. Abra picks
  up the apps on the Mac's next heartbeat.
