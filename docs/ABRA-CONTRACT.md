# fop-rbac ↔ daemon contract (via fop-appstore)

> **This replaces the retired "Abra clones this repo" model.** Per the FOP core
> team alignment (2026-07-13) and ADR-0023, the daemon **never reads this
> repo**. It polls **Rendered Manifests** in `farmer1st-common/fop-appstore`.
> This repo's job is to *produce* those manifests. The authoritative spec is
> `05.specs/02.abra/05-profiles-and-manifests.md`; this page is the working
> summary for this repo.

## The pipeline

```
profiles/ (this repo)  ──render/render.py──▶  manifests/  ──repository_dispatch──▶
fop-appstore (publishes)  ◀──ETag fast-poll──  fop daemon on each Mac
```

- **Profiles** (`profiles/`): catalog + roles + users + `devices.yml` — the
  human-edited config. CTO-gated PRs; validated by `scripts/validate.py`.
- **Rendered Manifest** (`render/render.py` output): what the daemon consumes.
  This repo holds **no appstore write credential** — CI dispatches
  `publish-manifests` and the appstore's own workflow commits (ADR-0023).
- The daemon identifies a machine by **serial → login** via
  `manifests/index.json` (rendered from `profiles/devices.yml`) and fetches
  `manifests/users/<login>.json`. Users are **keyed by GitHub login**
  (filename == `user:` == login; enforced by the validator).

## Rendered artifacts

`manifests/index.json`:

```json
{
  "devices": { "FCQN7GT76Y": "vireakyuth" },
  "users": {
    "vireakyuth": { "path": "manifests/users/vireakyuth.json",
                    "payload_sha256": "…", "version": 7 }
  }
}
```

`manifests/users/<login>.json` — schema `fop.rendered-manifest/v1`:

```json
{
  "schema": "fop.rendered-manifest/v1",
  "user": "vireakyuth",
  "brewfile": "brew \"git\"\ncask \"slack\"\n",
  "system": ["docker-desktop"],
  "whitelist": [],
  "payload_sha256": "…"
}
```

- `brewfile` — verbatim, fed straight to `brew bundle`; **the renderer
  resolves roles→apps, the daemon does not resolve**. Formulae + public casks
  only (ADR-0020) — App Store / direct-download apps are out of FOP scope
  (MDM/VPP handles those).
- `system[]` — trust-plane installer ids (admin-requiring installs).
- `whitelist[]` — tolerated self-installs the daemon must not reap (ADR-0011).
- Arrays are always present, never null.

## payload_sha256 — the interop crux

The daemon recomputes this and **refuses** a manifest whose hash differs from
the index (tamper → keep last-known-good). The recipe, byte-exact:

```python
payload = {"brewfile": brewfile, "system": system or [], "whitelist": whitelist or []}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
```

Golden fixture (verified identical to the daemon's Go `rbac.PayloadSHA256`):
brewfile `tap "farmer1st/fop"\nbrew "htop"\ncask "visual-studio-code"\n`,
system `[]`, whitelist `["docker"]` →
`f81b15bfd39fdb77603b1146971e3f805afb4e016cc4d0ab7922d3b68cb74484`.
`render/test_render.py` enforces this plus render determinism
(render-twice → byte-identical) on every CI run. **Never ship a render with a
failing golden test.**

## Out of scope for the daemon

`cloud:` blocks in role files (AWS grants, GitHub teams, Cloudflare groups)
are consumed by **Terraform** in this repo — the renderer ignores them and
they never appear in a manifest. The spec contains no secrets.

## Local tooling (dev only — NOT the daemon's model)

`scripts/abra.sh` and `scripts/abra_sim.py` are local simulators that resolve
profiles directly and converge a dev Mac via brew. Useful for testing what a
manifest *will contain*; the production path is always
render → appstore → daemon.

```bash
make validate                              # spec is coherent
.venv/bin/python render/test_render.py     # golden hash + determinism
.venv/bin/python render/render.py --out build   # what would be published
bash scripts/abra.sh --dry-run             # local converge preview
```
