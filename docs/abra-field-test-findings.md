# Abra WS-A field test — findings

**2026-07-20 · vireakyuth's Mac** (serial `FCQN7GT76Y`, mapped in `devices.yml`) ·
abra built from `8a4af78` · driven unprivileged via the dev affordances
(`ABRA_DESIRED_STATE`, verify → compute → publish harness) against the real
rendered `users/vireakyuth.json`. Abra repo not modified.

**Contract verified ✅** — `rbac.PayloadSHA256` matches this repo's renderer
byte-for-byte on live manifests; all 14 Go packages test green; every guard
failed closed (untrusted tap, `local_account` mismatch, reap). No half-done
states.

## Findings

1. **[decision needed] GUI casks can't install for standard (non-admin) users.**
   22 of 27 entitled apps failed writing `/Applications` (brew escalates to
   sudo; non-admin can't). `brewEnv`'s sealed env (rightly) blocks external
   `HOMEBREW_CASK_OPTS`, so only abra can fix it.
   **Proposal:** convenience plane passes `--appdir=$HOME/Applications --adopt`
   (user plane → user Applications; adopt handles pre-existing manual installs).
   Pkg-installer casks (`logi-options+`) need root regardless → `system[]`/MDM;
   fop-rbac will reclassify once direction is confirmed.

2. **`system[]` missing from the reap allowed-set** — a brew-installed
   `docker-desktop` (system[] in the roles) showed under "Would uninstall
   casks". Suggest `Compute` adds `m.System` to `Reap.Allowed.Casks`.
   Interim: per-user `overrides.add` in this repo.

3. **`local_account` needs a mapping source** — it defaults to the GitHub
   login; my macOS account is `vireakyuth.neak`, so `apply` refused (exit 13 —
   correct guard, wrong data). Proposal: `identity.localAccount` in the user
   spec, carried through the manifest.

4. **Bootstrap must `brew trust` third-party taps** — first converge dies on
   `hashicorp/tap/terraform` otherwise.

5. **Cosmetic** — `plan` lists already-installed casks as ToInstall;
   `reap --dry-run`'s expected exit-1 surfaces as an `Error:` line.

6. **`brewBundleTimeout = 10min` is tight for a first (multi-GB) converge** —
   fine if resume-next-tick is the intended recovery; confirming it's deliberate.

## Repo-side actions taken here

Role whitelists for engineer self-installs + the docker-desktop override
(`c43661a`) — verified via `reap --dry-run`: zero uninstalls. Real-manifest
fixture kit at `../fop-toolkit/fixtures/manifests/users/` so the golden tests
run un-skipped.

**Net:** core loop, hash contract, and fail-closed posture all check out on
production data. #1 is the one to settle before piloting on managed
(non-admin) Macs.
