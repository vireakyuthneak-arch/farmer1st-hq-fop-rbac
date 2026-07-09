#!/usr/bin/env python3
"""Validate the FOP spec and resolve what Abra would install for a user.

Two jobs:
  1. `validate`  — every catalog/role/user file matches its JSON Schema AND all
                   cross-references resolve (role apps exist in the catalog,
                   users reference real roles, overrides reference real apps,
                   device serials are unique). This is what CI runs.
  2. `resolve U` — print the final desired app set for user U (role apps, plus
                   overrides.add, minus overrides.remove), each resolved to its
                   catalog source/id. This is exactly the view Abra consumes.

Usage:
  python3 scripts/validate.py validate
  python3 scripts/validate.py resolve vireakyuth
"""
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML not installed. Run `make setup` (creates .venv) or "
             "`pip install pyyaml jsonschema`.")
try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("jsonschema not installed. Run `make setup` or "
             "`pip install pyyaml jsonschema`.")

ROOT = Path(__file__).resolve().parent.parent
FOP = ROOT / "fop"
SCHEMA = ROOT / "schema"


def load_yaml(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def load_schema(name: str) -> Draft202012Validator:
    with (SCHEMA / name).open() as f:
        return Draft202012Validator(json.load(f))


def load_all():
    catalog = load_yaml(FOP / "catalog.yml")
    roles = {p.stem: load_yaml(p) for p in sorted((FOP / "roles").glob("*.yml"))}
    users = {p.stem: load_yaml(p) for p in sorted((FOP / "users").glob("*.yml"))}
    return catalog, roles, users


def schema_errors(label, validator, doc):
    out = []
    for e in sorted(validator.iter_errors(doc), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in e.path) or "(root)"
        out.append(f"  {label}: {loc}: {e.message}")
    return out


def validate() -> int:
    catalog, roles, users = load_all()
    cat_v, role_v, user_v = (load_schema("catalog.schema.json"),
                             load_schema("role.schema.json"),
                             load_schema("user.schema.json"))
    errors = []

    errors += schema_errors("catalog.yml", cat_v, catalog)
    for name, doc in roles.items():
        errors += schema_errors(f"roles/{name}.yml", role_v, doc)
    for name, doc in users.items():
        errors += schema_errors(f"users/{name}.yml", user_v, doc)

    app_keys = set((catalog.get("apps") or {}).keys())

    # role apps must exist in the catalog
    for name, role in roles.items():
        for a in role.get("apps", []):
            if a not in app_keys:
                errors.append(f"  roles/{name}.yml: unknown app '{a}' (not in catalog)")

    # users must reference real roles; overrides must reference real apps
    seen_serials = {}
    for name, user in users.items():
        for r in user.get("roles", []):
            if r not in roles:
                errors.append(f"  users/{name}.yml: unknown role '{r}'")
        ov = user.get("overrides") or {}
        for a in (ov.get("add") or []) + (ov.get("remove") or []):
            if a not in app_keys:
                errors.append(f"  users/{name}.yml: override references unknown app '{a}'")
        for d in user.get("devices", []):
            s = d["serial"]
            if s in seen_serials:
                errors.append(f"  users/{name}.yml: device serial '{s}' already claimed by "
                              f"'{seen_serials[s]}'")
            seen_serials[s] = name

    if errors:
        print("FOP spec INVALID:\n" + "\n".join(errors))
        return 1
    print(f"FOP spec OK — {len(app_keys)} apps, {len(roles)} roles, {len(users)} users")
    return 0


def resolve(username: str) -> int:
    catalog, roles, users = load_all()
    if username not in users:
        sys.exit(f"unknown user '{username}' (have: {', '.join(users) or 'none'})")
    user = users[username]
    apps = catalog.get("apps") or {}

    # role apps (union across assigned roles), then apply per-user overrides
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

    print(f"# Desired app set for {username} (roles: {', '.join(user['roles'])})")
    print(f"# {len(desired)} apps — this is what Abra converges the Mac to:\n")
    for a in sorted(desired):
        app = apps[a]
        ver = f" @{app['version']}" if app.get("version") else ""
        print(f"  {a:<16} {app['source']:<8} {app['id']}{ver}")
    return 0


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("validate", "resolve"):
        sys.exit(__doc__)
    if sys.argv[1] == "validate":
        return validate()
    if len(sys.argv) < 3:
        sys.exit("resolve needs a username, e.g. `resolve vireakyuth`")
    return resolve(sys.argv[2])


if __name__ == "__main__":
    raise SystemExit(main())
