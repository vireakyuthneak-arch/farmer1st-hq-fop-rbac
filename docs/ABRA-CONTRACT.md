# Abra ↔ RBEC contract

What Abra (the background binary on each Mac — built separately, not in this
repo) must read from the **RBEC** (Role-Based Entitlement Contract, the
YAML under `fop/`) and what it is expected to do with it. This is the complete
interface: an Abra implementation that follows this document needs nothing else
from FOP.

A working reference implementation of everything below exists in this repo as
[`scripts/abra.sh`](../scripts/abra.sh) (one-shot bash) and
[`scripts/abra_sim.py`](../scripts/abra_sim.py) (stateful simulator).

---

## 1. Inputs Abra must read

Three file sets, all plain YAML, all in this repo:

| Path | One file per | Abra uses it to |
|------|--------------|-----------------|
| `fop/catalog.yml` | — (single file) | know **how** to install each app (source, id, version) |
| `fop/roles/*.yml` | role | know **what** apps a role grants |
| `fop/users/*.yml` | person | map **this device** to a person and their role(s) + overrides |

Formal JSON Schemas live in [`schema/`](../schema): `catalog.schema.json`,
`role.schema.json`, `user.schema.json`. Every file carries `schemaVersion: 1`;
Abra should refuse files with a schemaVersion it does not understand.

Abra needs **read-only** access to these files (git clone/pull, or a rendered
copy delivered by CI). It never writes to the RBEC.

## 2. Device → user resolution

1. Read the Mac's hardware serial:
   `system_profiler SPHardwareDataType` → `Serial Number` (e.g. `FCQN7GT76Y`).
2. Find the **one** user file whose `devices[].serial` contains it:

   ```yaml
   # fop/users/vireakyuth.yml
   user: vireakyuth
   devices:
     - serial: FCQN7GT76Y
       hostname: vireakyuth-mac
   roles:
     - devops-engineer
   ```

3. If no user claims the serial: **do nothing** (an unassigned Mac is not an
   error to converge, it's a machine outside the fleet — log and exit).

The RBEC validator guarantees a serial is claimed by at most one user, so
"first match" is safe.

## 3. Resolving the desired app set

For the resolved user:

```
desired = union of apps[] across all roles in user.roles   # order-preserving, deduped
        + user.overrides.add                                # extra apps for this person
        - user.overrides.remove                             # apps this person must NOT get
```

- A user may have **multiple roles** (e.g. `[uiux-designer, project-manager]`);
  the union is deduplicated.
- Every name in `apps`, `overrides.add`, `overrides.remove` is a **catalog
  key**, guaranteed by the validator to exist in `fop/catalog.yml`.

`make resolve USER=<name>` (or `scripts/validate.py resolve <name>`) prints the
exact expected result — use it as the oracle when testing an Abra build.

## 4. Installing: the catalog entry tells Abra how

Each catalog entry:

```yaml
terraform:
  name: Terraform
  source: formula                  # formula | cask | mas | direct
  id: hashicorp/tap/terraform      # meaning depends on source (below)
  version: latest                  # 'latest' or a pinned string like "3.12"
  category: iac
```

| `source` | `id` is | Install with | Notes |
|----------|---------|--------------|-------|
| `formula` | Homebrew formula name (may be tap-qualified, e.g. `hashicorp/tap/terraform`) | `brew install --formula <id>` | CLI tools |
| `cask` | Homebrew cask token | `brew install --cask --adopt <id>` | GUI apps. `--adopt` takes over an existing copy instead of erroring |
| `mas` | numeric Mac App Store id (quoted string) | **do not auto-install.** Detect presence (`mas list`, or the app bundle in `/Applications`); if missing, report it for MDM/VPP or a one-time manual App Store install | `mas install` needs a signed-in Apple account and can trigger admin prompts — the RBEC policy is cask-first, and `mas` is reserved for Apple-exclusive apps (iWork, Xcode, TestFlight) |
| `direct` | https URL to a signed pkg/dmg | download → **verify `sha256`** → `installer -pkg` | `sha256` field is mandatory; a mismatch is a hard stop |

Homebrew itself is a bootstrap prerequisite Abra must ensure before its first
converge; it is not a catalog app.

### `version` semantics

- `latest` — track upstream: install if missing, **upgrade when outdated**.
- pinned (e.g. `"3.12"`) — ensure present at that major/track (for Homebrew this
  is usually encoded in the id itself: `python@3.12`, `node@20`); **never**
  force-upgrade a pinned app.

### Install placement / privileges

- Casks: prefer `--appdir=$HOME/Applications` (no admin rights needed). Installs
  into `/Applications` and `direct` pkgs need elevation — that belongs to Abra's
  privileged plane, not the user session.
- Inline `#` comments are legal YAML anywhere in the RBEC — parse accordingly
  (use a real YAML parser; don't grep values).

## 5. Convergence rules (per app, idempotent)

| Observed state | Action |
|----------------|--------|
| not installed | install |
| installed, current | skip |
| installed, outdated, `version: latest` | upgrade |
| installed, pinned version | skip (never force-upgrade) |
| app bundle already present but **not** managed by brew (manual install) | skip — do not create a duplicate copy |
| `mas` app missing | report only (App Store / MDM install) — never trigger sign-in or admin prompts |
| in a previous converge but no longer in `desired` | **reap** (uninstall) |

Abra runs this loop on a heartbeat (the reference cadence is minutes, not
hours) and must be safe to re-run at any frequency: a converged machine
produces zero actions.

Failures must be **per-app and non-fatal**: one app failing to install must not
stop the rest of the converge. Surface the underlying installer error (brew/mas
output) in the log/report.

## 6. What the RBEC guarantees Abra (so it can skip re-checking)

CI runs `make validate` on every change, which enforces:

- every file matches its JSON Schema (required fields, `version` present,
  `mas` ids numeric, `direct` entries carry a 64-hex `sha256`);
- every app referenced by a role or an override exists in the catalog;
- every role referenced by a user has a role file;
- keys are lowercase kebab-case;
- no device serial is claimed by two users.

Abra may therefore treat a fetched RBEC as internally consistent, but should
still fail gracefully on parse errors (a mid-edit state should never brick a
converge — keep using the last good copy).

## 7. Out of scope for Abra

- `cloud:` blocks in role files (AWS account/permission set, GitHub org/teams)
  are consumed by **Terraform** during onboarding, not by Abra. Abra ignores
  them entirely.
- The RBEC contains **no secrets** and no credentials; Abra must not expect or
  store any there.

## 8. Quick self-test for an Abra implementation

```bash
make setup && make validate                    # spec is coherent
make resolve USER=vireakyuth                   # expected app set (the oracle)
bash scripts/abra.sh --dry-run                 # reference resolution on this Mac
bash scripts/abra.sh --user test-user --dry-run   # forced-user resolution
bash scripts/abra.sh --serial NOPE --dry-run   # unassigned device → clean no-op
```

(For the multi-role union case, give any user a second role in their `roles:`
list and re-run `resolve` — the union must be deduplicated.)

An Abra build is correct when, for any user, its computed install plan matches
`resolve`'s output, and running it twice in a row produces zero actions the
second time.
