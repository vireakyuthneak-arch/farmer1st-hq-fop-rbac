# Leave Tracker × FOP RBAC — how they work together

The Leave Tracker no longer decides who can do what. **FOP RBAC** (this repo)
owns roles; the Leave Tracker reads them at request time from a Cloudflare D1
database that RBAC materializes and keeps in sync. Role changes are YAML PRs
here — the app never redeploys for them.

## The big picture

```mermaid
flowchart LR
  subgraph rbac["fop-rbac repo — source of truth"]
    Y["profiles/*.yml<br/>users · roles · applications"] --> PR["Pull request<br/>(review = access approval)"]
    PR -->|"merge to main"| CI["GitHub Action<br/>sync-rbac-d1"]
  end

  CI -->|"full-refresh sync<br/>wrangler d1 execute"| D1[("fop-rbac D1<br/>app_role table")]

  subgraph cf["Cloudflare"]
    ACC["Cloudflare Access<br/>(Google SSO)"] --> W["leave-tracker Worker"]
    W -->|"SELECT role … (read-only)"| D1
    W --> LDB[("leave-tracker D1<br/>employees · leave_log<br/>holidays · settings")]
  end

  U(("Employee")) --> ACC
```

Two databases, two owners, joined by email at request time:

| Database | Owned by | Holds | Written by |
|---|---|---|---|
| `fop-rbac` D1 | **RBAC** | `app_role` — who is `employee` / `approver` / `admin` per app | fop-rbac CI only |
| `leave-tracker` D1 | **the app** | employees, leave log, holidays, settings — all leave data | the app only |

## What happens on every request

```mermaid
sequenceDiagram
  autonumber
  participant E as Employee
  participant A as Cloudflare Access
  participant W as leave-tracker Worker
  participant R as fop-rbac D1 (read-only)
  participant L as leave-tracker D1

  E->>A: open the app (Google SSO)
  A->>W: request + Cf-Access-Authenticated-User-Email
  W->>R: SELECT role WHERE email = ? AND app = 'leave-tracker'
  R-->>W: admin / approver / employee (no row → employee)
  W->>L: read or write leave data — gated by the role
  L-->>W: balances · log · pending queue
  W-->>E: UI shows only what the role allows
```

Identity comes from the **verified Access JWT header**, never from anything the
client can set. The role comes from the RBAC D1 — **fail closed**: a missing
row, an unknown role string, or a lookup error all degrade to `employee`
(own data only). One hardcoded break-glass admin survives an RBAC outage.

## What happens when a role changes

```mermaid
sequenceDiagram
  autonumber
  participant M as Maintainer
  participant G as GitHub (fop-rbac)
  participant CI as sync-rbac-d1 Action
  participant D as fop-rbac D1
  participant W as leave-tracker Worker

  M->>G: PR — edit a user's roles: list (or a role's grants)
  G->>G: validate gate + review + merge
  G->>CI: merge to main triggers the sync
  CI->>D: regenerate SQL, full-refresh app_role rows
  Note over W: nothing to do — no redeploy, no restart
  W->>D: very next request reads the new role
```

Offboarding works the same way: remove the user file (or the role line) and the
sync **deletes** their rows — access is gone on the next request.

## How a person's role is computed

Permissions attach to **roles**, never to individual people. A person's
effective app role = the strongest grant across every role they hold, with the
app's `defaultRole` as the floor for everyone:

```mermaid
flowchart TD
  U["user file: damon-hase.yml<br/>roles: [program-manager]"] --> R1["role: program-manager<br/>appRoles → leave-tracker: admin"]
  A["applications.yml — leave-tracker<br/>vocabulary: employee → approver → admin<br/>defaultRole: employee"] --> RES{"strongest wins"}
  R1 --> RES
  RES --> OUT[("app_role row<br/>damon.hase@… → admin")]
```

So: **assign a role, get its whole bundle** — appointing someone
`program-manager` automatically makes them a leave-tracker `admin`; removing
the line revokes it. The current tiers:

| Tier | May do | Held today by |
|---|---|---|
| `employee` (default) | own balances, own requests | everyone |
| `approver` | + approve/reject, see all logs & balances | *(vacant — ready for future use)* |
| `admin` | + settings, holidays, member management, on-behalf entries | **Norbert** (executive) · **Damon** (program-manager) |

## The contract in one box

- Leave Tracker **reads only** (`SELECT`) from the RBAC D1 — fop-rbac CI is the sole writer.
- **Fail closed** — anything unexpected resolves to `employee`.
- **No role caching** beyond a request — that's what makes revocation instant.
- Leave *data* never moves — RBAC holds roles, nothing else.
- Audit trail = **git history** (who changed what, reviewed by whom) + the
  Actions log (when it materialized). The D1 is a projection; the repo wins.

## Related docs

- [`leave-tracker-integration.md`](leave-tracker-integration.md) — the reference contract + monitoring guide
- [`leave-tracker-claude-prompt.md`](leave-tracker-claude-prompt.md) — paste-ready prompt to implement the app-side changes
- [`APP-RBAC.md`](APP-RBAC.md) — the general application-RBAC consumer contract (KV variant)
