# Abra WS-A field test — findings

**2026-07-20/21 · vireakyuth's Mac** (standard/non-admin user, serial `FCQN7GT76Y`)
· stock abra `8a4af78` → `964ee08` · real rendered manifests from this repo,
driven unprivileged via the dev affordances. Abra repo never modified.

**Contract verified ✅** — Go `PayloadSHA256` matches the renderer byte-for-byte
on live manifests; all 14 packages test green; every guard fails closed.

**Latest converge (stock `964ee08` + reclassified spec): 35/37 entitled items
converged, reap removed 0.** Remaining 2 failures are environmental, not bugs:
`terraform` (macOS 27 beta has no bottle; source-build needs Xcode 27) and
`docker-desktop` upgrade (root-owned helpers — see #2).

## Findings

1. **Non-admin cask installs — ✅ RESOLVED.** Standard users can't write
   `/Applications`, so 22/27 GUI apps failed. Daemon fix shipped in `964ee08`
   (`HOMEBREW_CASK_OPTS=--appdir=<home>/Applications --adopt` in brewEnv +
   pre-create); fop-rbac moved the 4 pkg-installer casks (root regardless —
   see [`app-privilege-audit.md`](app-privilege-audit.md)) to `system[]`.
   Verified: 20/22 casks into `~/Applications`, zero admin prompts, manual
   Spotify adopted in place.

2. **`system[]` missing from the reap allowed-set — open.** A brew-managed
   docker-desktop would be reaped as "unmanaged", and its UPGRADE fails in the
   convenience plane anyway (removes root-owned launchd helpers → sudo). It
   belongs to the trust plane end-to-end. Fix: `Compute` adds `m.System` to
   `Reap.Allowed.Casks`; then fop-rbac drops its per-user `overrides.add`
   crutch and the convenience plane never touches it again.

3. **`local_account` mapping — spec side ✅ shipped, daemon one-liner open.**
   It defaults to the GitHub login; my macOS account is `vireakyuth.neak`, so
   the converge guard refused (exit 13 — correct). Manifests now carry
   `local_account` (all 11 users declare `identity.localAccount`; additive,
   outside the hashed payload, ignored by the current parser — your rbac tests
   pass unchanged). Remaining: add `LocalAccount` to `RenderedManifest`,
   prefer it in `Compute` (fallback `m.User`) — prototyped, works.

4. **`brew trust` must run EVERY converge — open.** Measured: trust survives
   exactly one converge; each run's auto-update moves the tap revision and
   voids the trust entry (reproduced twice). Fix: trust every
   manifest-declared tap at converge start, and/or pin
   `HOMEBREW_NO_AUTO_UPDATE=1` in brewEnv with updates as a scheduled job.

5. **Cosmetic** — `plan` doesn't see installed casks (lists them as
   ToInstall); dry-run reap's expected exit-1 prints as `Error:`.

6. **`brewBundleTimeout = 10min`** is tight for a first multi-GB converge —
   fine if resume-next-tick is the intended recovery; please confirm.

## Net

Core loop, hash contract, and fail-closed posture all hold on production data,
and the non-admin blocker is resolved. Remaining daemon work: #2 (one line),
#3 (one line), #4 (trust-per-converge policy).
