# Abra WS-A field test — findings (real Mac, real manifest)

**Date:** 2026-07-20 · **Machine:** vireakyuth's Mac (serial `FCQN7GT76Y`, mapped in
`profiles/devices.yml`) · **Abra:** built from `8a4af78` (pre-freeze WS-A) ·
**Manifest:** the real rendered `users/vireakyuth.json` from this repo.

**Method:** unprivileged harness using abra's own dev affordances
(`ABRA_DESIRED_STATE`, `ABRA_MACHINE_TOKEN`): drove `rbac.VerifyManifest →
desiredstate.Compute → Publish`, then the real `convenience plan`,
`reap --dry-run`, and two `apply` attempts. The abra repo was not modified
(harness injected via `go build -overlay`).

## The contract holds ✅

- `rbac.PayloadSHA256` reproduced this repo's renderer-declared hashes
  **byte-for-byte on live production manifests** — and real manifests fed
  through the golden fixture tests pass.
- All 14 Go packages test green on this machine.
- Every guard failed **closed**: untrusted tap stopped brew, `local_account`
  mismatch stopped converge (exit 13), reap removed nothing it shouldn't.
  No half-done states anywhere.

## Findings (priority order)

### 1. [design decision needed] Convenience-plane cask installs require admin on standard-user Macs

The test account is not in `admin`, so every GUI cask failed writing
`/Applications` (`sudo: a terminal is required…`) — 22 of 27 entitled items,
each rolled back cleanly by brew. `brewEnv`'s sealed environment (correctly)
blocks a `HOMEBREW_CASK_OPTS` override from outside, so only abra can fix this.

**Proposal:** the convenience plane passes `--appdir=$HOME/Applications
--adopt` — the per-user plane installs to the per-user Applications dir
(symmetry: trust plane = machine-wide, convenience = user). `--adopt` also
resolves conflicts with pre-existing manual installs (e.g. a hand-installed
VS Code). Caveat: **pkg-installer casks** (`logi-options+`) require root
regardless of appdir → they belong in `system[]`/MDM; fop-rbac will
reclassify them once the direction is confirmed.

### 2. `system[]` items are missing from the reap allowed-set

`docker-desktop` is `system[]` in the roles, but a brew-installed copy showed
under "Would uninstall casks" — the convenience reap would remove a
trust-plane app. Suggest `Compute` adds `m.System` to `Reap.Allowed.Casks`
(or this repo's renderer includes system entries in the whitelist — either
side works, coordinate so it's exactly one of them). Interim workaround in
this repo: a per-user `overrides.add: [docker-desktop]`.

### 3. `local_account` needs a real mapping source

`Compute` defaults `local_account` to the GitHub login; this Mac's account is
`vireakyuth.neak` vs login `vireakyuth`, so `apply` refused (exit 13 — good
guard, wrong data). **Proposal:** an `identity.localAccount` field in this
repo's user spec, carried through the manifest into desired-state.

### 4. Bootstrap must handle Homebrew tap trust

Current Homebrew refuses third-party taps until `brew trust <tap>` — the first
converge on a fresh Mac dies on `hashicorp/tap/terraform`. One line in the
Bootstrapper.

### 5. Cosmetic: `plan` doesn't see installed casks

Successfully installed casks (claude-code, codex, dbeaver-community…) still
appear in `ToInstall`. Related: `reap --dry-run`'s expected exit-1-on-removals
surfaces as an `Error:` line in the report.

### 6. `brewBundleTimeout = 10min` is tight for a first converge

A first converge pulling multiple GB will exceed it. If "resume next tick" is
the intended recovery, all good — flagging to confirm it's deliberate.

## Repo-side actions already taken here

- Role whitelists for engineer self-installs (`go`, `pyenv`, `python@3.14`,
  `ripgrep` / `infracost`, `mas`) — verified via `reap --dry-run`: zero
  uninstalls (`c43661a`).
- Per-user `docker-desktop` override pending finding #2.
- Real-manifest fixture kit placed at `../fop-toolkit/fixtures/manifests/users/`
  (local convenience so the golden tests run un-skipped).

## Net

Core loop, hash contract, and fail-closed posture all check out against
production data. Finding #1 is the one to decide before any pilot on managed
(non-admin) Macs — the fop-rbac side will pair on whichever option is chosen.
