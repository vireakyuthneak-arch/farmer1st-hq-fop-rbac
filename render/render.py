#!/usr/bin/env python3
"""fop-render — render Profiles into the daemon's Rendered Manifests.

Reads profiles/ (catalog, roles, users, devices.yml), resolves each user's
apps (same algebra as scripts/validate.py resolve), and emits:

    <out>/manifests/users/<login>.json   (schema fop.rendered-manifest/v1)
    <out>/manifests/index.json           (devices map + per-user path/sha/version)

Contract (05.specs/02.abra/05-profiles-and-manifests.md):
  - brewfile: verbatim Brewfile string the daemon feeds to `brew bundle` —
    the renderer resolves roles->apps; the daemon never resolves.
  - system[]: trust-plane installer ids (admin-requiring installs).
  - whitelist[]: tolerated self-installs (ADR-0011). Arrays, never null.
  - payload_sha256: canonical-JSON hash of {brewfile, system, whitelist};
    the daemon recomputes it and refuses a mismatch (keeps last-known-good).

Determinism is a hard requirement: render twice -> byte-identical output.
Sorted app lines, sorted keys, no timestamps. Manifest versions are carried
forward from a previous index (--prev-index) and bumped only when the
payload_sha256 changes.

Usage:
  python3 render/render.py --out build [--prev-index path/to/index.json]
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from validate import load_all, load_devices  # noqa: E402

SCHEMA = "fop.rendered-manifest/v1"


def payload_sha256(brewfile: str, system: list, whitelist: list) -> str:
    """The interop crux — byte-identical to the daemon's Go rbac.PayloadSHA256.

    Canonical form: sorted keys, compact separators, no ASCII escaping,
    UTF-8 bytes, no trailing newline. Arrays default to [] (never null).
    """
    payload = {"brewfile": brewfile, "system": system or [], "whitelist": whitelist or []}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def resolve_apps(catalog: dict, roles: dict, user: dict) -> list:
    """Union of role apps + overrides.add - overrides.remove (order-free)."""
    desired = []
    for r in user["roles"]:
        for a in roles[r].get("apps", []):
            if a not in desired:
                desired.append(a)
    ov = user.get("overrides") or {}
    for a in ov.get("add") or []:
        if a not in desired:
            desired.append(a)
    for a in ov.get("remove") or []:
        if a in desired:
            desired.remove(a)
    return desired


def render_brewfile(catalog: dict, app_keys: list) -> str:
    """Deterministic Brewfile: brew lines then cask lines, each sorted by id.

    No tap lines today — every catalog entry is public homebrew/cask
    (ADR-0020). When private formulae land, taps go first: tap "<name>"\\n.
    """
    apps = catalog["apps"]
    brews = sorted(apps[k]["id"] for k in app_keys if apps[k]["source"] == "formula")
    casks = sorted(apps[k]["id"] for k in app_keys if apps[k]["source"] == "cask")
    lines = [f'brew "{i}"' for i in brews] + [f'cask "{i}"' for i in casks]
    return "\n".join(lines) + "\n" if lines else ""


def render_user(catalog: dict, roles: dict, user: dict) -> dict:
    system = sorted({s for r in user["roles"] for s in roles[r].get("system", []) or []})
    whitelist = sorted({w for r in user["roles"] for w in roles[r].get("whitelist", []) or []})
    brewfile = render_brewfile(catalog, resolve_apps(catalog, roles, user))
    return {
        "schema": SCHEMA,
        "user": user["user"],
        "brewfile": brewfile,
        "system": system,
        "whitelist": whitelist,
        "payload_sha256": payload_sha256(brewfile, system, whitelist),
    }


def write_json(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build", help="output directory (default: build)")
    ap.add_argument("--prev-index", help="previous manifests/index.json for version carry-forward")
    args = ap.parse_args()

    catalog, roles, users = load_all()
    devices_doc = load_devices()
    if devices_doc is None:
        sys.exit("render: profiles/devices.yml missing")

    prev_users = {}
    if args.prev_index:
        prev_users = json.loads(Path(args.prev_index).read_text()).get("users", {})

    out = Path(args.out)
    index_users = {}
    for login in sorted(users):
        manifest = render_user(catalog, roles, users[login])
        rel = f"manifests/users/{login}.json"
        write_json(out / rel, manifest)
        prev = prev_users.get(login, {})
        version = prev.get("version", 0)
        if prev.get("payload_sha256") != manifest["payload_sha256"]:
            version += 1
        index_users[login] = {
            "path": rel,
            "payload_sha256": manifest["payload_sha256"],
            "version": version,
        }

    write_json(out / "manifests" / "index.json", {
        "devices": dict(sorted((devices_doc.get("devices") or {}).items())),
        "users": index_users,
    })
    print(f"rendered {len(index_users)} manifests + index -> {out}/manifests/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
