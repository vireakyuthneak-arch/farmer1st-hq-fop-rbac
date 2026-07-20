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

1. **[decision needed] GUI casks can't install for standard (non-admin) users
   — ✅ fix PROTOTYPED & VALIDATED.**
   22 of 27 entitled apps failed writing `/Applications` (brew escalates to
   sudo; non-admin can't). `brewEnv`'s sealed env (rightly) blocks external
   `HOMEBREW_CASK_OPTS`, so only abra can fix it.
   **Validated fix** (built via `go build -overlay`, repo untouched; re-ran the
   full converge on the same standard-user Mac): one line in `renderBrewfile`
   (`internal/convenience/converge.go`):

   ```go
   b.WriteString("cask_args appdir: \"~/Applications\", adopt: true\n")
   ```

   **Result: 20/22 entitled casks installed** to `~/Applications`, zero admin
   prompts; a pre-existing manual Spotify was adopted in place; reap ok,
   removed 0. The only 2 failures were `logi-options+` and `privileges` —
   pkg-installer casks that run `sudo installer` regardless of appdir (see
   [`app-privilege-audit.md`](app-privilege-audit.md): exactly 4 such casks in
   the whole 55-app catalog). Those belong in `system[]`/MDM; fop-rbac will
   reclassify on your confirmation. Known cosmetic: a manually-installed app in
   `/Applications` (e.g. VS Code) gets a second, brew-managed copy in
   `~/Applications` — adopt only inspects the target dir.

2. **`system[]` missing from the reap allowed-set** — a brew-installed
   `docker-desktop` (system[] in the roles) showed under "Would uninstall
   casks". Suggest `Compute` adds `m.System` to `Reap.Allowed.Casks`.
   Interim: per-user `overrides.add` in this repo.

3. **`local_account` needs a mapping source — ✅ spec side shipped** — it
   defaults to the GitHub login; my macOS account is `vireakyuth.neak`, so
   `apply` refused (exit 13 — correct guard, wrong data). fop-rbac manifests
   now carry `local_account` (defaults to login; `identity.localAccount`
   overrides — see ABRA-CONTRACT.md). Additive: outside the hashed payload,
   and your parser ignores unknown keys (your `internal/rbac` tests pass on
   the new manifests unchanged). Daemon remainder is a one-liner: add
   `LocalAccount` to `RenderedManifest` and prefer it in `Compute`
   (fallback `m.User`) — **prototyped & validated**: with that line overlaid,
   the guard passed from pure manifest data (all 11 company users now
   declare `identity.localAccount`; manifests always carry `local_account`).

4. **`brew trust` must be asserted by the daemon, not just bootstrap** — the
   first converge dies on `hashicorp/tap/terraform`, and trust proved
   non-durable in testing (invalidated after a tap update mid-run). Suggest:
   trust every manifest-declared tap at the start of each converge
   (the manifest's tap list is exactly the right allowlist).

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
