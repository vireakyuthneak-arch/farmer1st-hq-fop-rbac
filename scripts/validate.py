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
FOP = ROOT / "profiles"
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


def load_devices():
    path = FOP / "devices.yml"
    return load_yaml(path) if path.exists() else None


def load_applications():
    path = FOP / "applications.yml"
    return load_yaml(path) if path.exists() else None


def schema_errors(label, validator, doc):
    out = []
    for e in sorted(validator.iter_errors(doc), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in e.path) or "(root)"
        out.append(f"  {label}: {loc}: {e.message}")
    return out


def validate() -> int:
    catalog, roles, users = load_all()
    devices = load_devices()
    applications = load_applications()
    cat_v, role_v, user_v, dev_v, app_v = (load_schema("catalog.schema.json"),
                                           load_schema("role.schema.json"),
                                           load_schema("user.schema.json"),
                                           load_schema("devices.schema.json"),
                                           load_schema("applications.schema.json"))
    errors = []
    warnings = []

    errors += schema_errors("catalog.yml", cat_v, catalog)
    if devices is None:
        errors.append("  devices.yml: missing (serial -> user map is required)")
    else:
        errors += schema_errors("devices.yml", dev_v, devices)
        for serial, login in (devices.get("devices") or {}).items():
            if login not in users:
                errors.append(f"  devices.yml: serial '{serial}' maps to unknown user '{login}'")
    if applications is None:
        errors.append("  applications.yml: missing (the app registry is required "
                      "— terraform reads it unconditionally)")
        app_reg = {}
    else:
        errors += schema_errors("applications.yml", app_v, applications)
        app_reg = applications.get("applications") or {}
        for aid, app in app_reg.items():
            default = app.get("defaultRole")
            if default and default not in (app.get("roles") or []):
                errors.append(f"  applications.yml: {aid}: defaultRole '{default}' "
                              f"is not in its roles vocabulary")
    for name, doc in roles.items():
        errors += schema_errors(f"roles/{name}.yml", role_v, doc)
    for name, doc in users.items():
        errors += schema_errors(f"users/{name}.yml", user_v, doc)

    app_keys = set((catalog.get("apps") or {}).keys())

    # filename must equal the declared name — terraform and abra key off the
    # file, so a mismatch means two identities for one person/role
    for name, role in roles.items():
        if role.get("role") != name:
            errors.append(f"  roles/{name}.yml: 'role: {role.get('role')}' must match filename")
    for name, user in users.items():
        if user.get("user") != name:
            errors.append(f"  users/{name}.yml: 'user: {user.get('user')}' must match filename")

    # role apps must exist in the catalog
    for name, role in roles.items():
        for a in role.get("apps", []):
            if a not in app_keys:
                errors.append(f"  roles/{name}.yml: unknown app '{a}' (not in catalog)")

    # appRoles: every app id must exist in the registry; every value must be
    # inside that app's ordered vocabulary (fail-closed, like all cross-refs)
    granted_apps = set()
    for name, role in roles.items():
        for aid, rval in (role.get("appRoles") or {}).items():
            if aid not in app_reg:
                errors.append(f"  roles/{name}.yml: appRoles references unknown "
                              f"application '{aid}' (not in applications.yml)")
                continue
            granted_apps.add(aid)
            vocab = app_reg[aid].get("roles") or []
            if rval not in vocab:
                errors.append(f"  roles/{name}.yml: appRoles.{aid}: '{rval}' is not "
                              f"in that app's vocabulary ({', '.join(vocab)})")
    for aid, app in app_reg.items():
        if aid not in granted_apps and not app.get("defaultRole"):
            warnings.append(f"  applications.yml: '{aid}' is granted by no role "
                            f"and has no defaultRole (dead entry)")

    # team rule (2026-07-14): any role that ships node/npm must also ship nvm
    node_keys = {"node", "node-22"}
    for name, role in roles.items():
        apps = set(role.get("apps", []))
        if apps & node_keys and "nvm" not in apps:
            warnings.append(f"  roles/{name}.yml: has a node stack "
                            f"({', '.join(sorted(apps & node_keys))}) but no nvm")

    # users must reference real roles; overrides must reference real apps
    seen_emails = {}
    for name, user in users.items():
        email = (user.get("identity") or {}).get("email", "")
        if email != email.lower():
            errors.append(f"  users/{name}.yml: email '{email}' must be lowercase "
                          f"(it is the KV key)")
        if email.lower() in seen_emails:
            errors.append(f"  users/{name}.yml: email '{email}' already used by "
                          f"'{seen_emails[email.lower()]}' (KV keys would collide)")
        seen_emails[email.lower()] = name
        for r in user.get("roles", []):
            if r not in roles:
                errors.append(f"  users/{name}.yml: unknown role '{r}'")
        ov = user.get("overrides") or {}
        for a in (ov.get("add") or []) + (ov.get("remove") or []):
            if a not in app_keys:
                errors.append(f"  users/{name}.yml: override references unknown app '{a}'")
        # spec rule: the user key IS the GitHub login — when the handle is
        # recorded it must equal the filename stem
        gh = (user.get("identity") or {}).get("github")
        if gh and gh != name:
            errors.append(f"  users/{name}.yml: identity.github '{gh}' must equal "
                          f"the user key '{name}' (users are login-keyed)")

        # a user whose roles grant GitHub teams eventually needs a real handle;
        # warn (not error) so app delivery isn't blocked while logins are
        # collected — terraform hard-fails at grant time if still missing
        needs_github = any(
            (roles.get(r, {}).get("cloud") or {}).get("github", {}).get("teams")
            for r in user.get("roles", [])
        )
        if needs_github and not gh:
            warnings.append(f"  users/{name}.yml: roles grant GitHub teams but "
                            f"identity.github is not set yet — the daemon keys users by GitHub "
                            f"login, so this Mac cannot be served until the real login lands "
                            f"(also required before enable_github)")

    if errors:
        print("FOP spec INVALID:\n" + "\n".join(errors))
        return 1
    if warnings:
        print("FOP spec warnings:\n" + "\n".join(warnings))
    n_dev = len((devices or {}).get("devices") or {})
    n_reg = len(app_reg)
    print(f"FOP spec OK — {len(app_keys)} apps, {len(roles)} roles, "
          f"{len(users)} users, {n_dev} devices, {n_reg} applications")
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

    applications = (load_applications() or {}).get("applications") or {}
    effective = {}
    for aid, app in applications.items():
        idxs = [app["roles"].index(roles[r]["appRoles"][aid])
                for r in user["roles"]
                if aid in (roles[r].get("appRoles") or {})]
        if app.get("defaultRole"):
            idxs.append(app["roles"].index(app["defaultRole"]))
        if idxs:
            effective[aid] = (app["roles"][max(idxs)], app["kind"])
    if effective:
        print(f"# Application roles (strongest-wins; what the fop-rbac KV doc carries):")
        for aid in sorted(effective):
            role_name, kind = effective[aid]
            tag = "" if kind == "internal-cf" else "   (external — recorded, NOT enforced)"
            print(f"#   {aid:<16} {role_name}{tag}")
        print()
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
