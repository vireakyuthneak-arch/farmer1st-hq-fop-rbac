# App privilege audit — what needs root, what doesn't

**For the abra daemon owner** (companion to
[`abra-field-test-findings.md`](abra-field-test-findings.md) finding #1).
Classified from brew's own artifact metadata — regenerate anytime with
`scripts/audit-privileges.py`. Snapshot: 2026-07-20, 55 catalog apps.

## The rule

An install's privilege need is decided by the cask's **artifact type**, not the
app:

| Artifact | Install mechanics | Root? |
|---|---|---|
| formula | unpack under `/opt/homebrew` (user-owned) | **never** |
| cask `app` / `binary` | copy a bundle into the appdir | **no — if** the appdir is user-writable (`--appdir=$HOME/Applications`); the `/Applications` default needs admin on standard-user Macs |
| cask `pkg` / `installer` | runs Apple's `installer` | **always** — no appdir setting changes this |

## Category A — formulae (17) · never root · convenience plane ✅

`awscli, cloudflare-wrangler, docker, docker-compose, fnm, gh, git, kubectl,
node, node20, nvm, ollama, postgresql, python, terraform, uv` *(+ any added
later — formulae are safe by construction)*

## Category B — app/binary casks (34) · convenience plane, needs the user-appdir decision

Everything from Chrome/Slack/VS Code to Figma/Sketch/Zen — 34 of 38 casks.
These install **without root** the moment the convenience plane passes
`--appdir=$HOME/Applications --adopt` (findings doc #1). Until then they fail
on every standard-user Mac.

One special case: **docker-desktop** — installs as a plain `app` (user-space),
but requires a **privileged helper at first launch**, so it stays `system[]`
regardless of the appdir decision.

## Category C — pkg/installer casks (4) · ROOT always · belongs in `system[]` / MDM

| App | Cask | Artifact | Granted by role(s) |
|---|---|---|---|
| Logi Options+ | `logi-options+` | installer | devops-engineer |
| Privileges | `privileges` | pkg | backend-engineer, devops-engineer |
| Microsoft Teams | `microsoft-teams` | pkg | program-manager |
| Zoom | `zoom` | pkg | program-manager |

These four can never be installed by the convenience plane on a standard-user
Mac. **Done:** all four now live in `system[]` (trust plane) per the CTO
decision + abra `964ee08` — the convenience session set contains no
root-requiring casks.

## Net for abra

- Implementing `--appdir=$HOME/Applications --adopt` unlocks **34/38 casks +
  all 17 formulae** for standard users — 93% of the catalog.
- The remaining 4 (plus docker-desktop's helper) are exactly what `system[]`
  exists for; fop-rbac will reclassify on your confirmation.
- Found and fixed during the audit: brew renamed Linear's token
  (`linear-linear` → `linear`); the catalog now pins the new token — worth a
  periodic `audit-privileges.py` run to catch upstream renames early.
