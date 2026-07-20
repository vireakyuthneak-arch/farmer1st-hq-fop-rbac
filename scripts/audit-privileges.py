#!/usr/bin/env python3
"""audit-privileges.py — classify every catalog app by the privilege its
INSTALL needs, from brew's own artifact metadata (docs/app-privilege-audit.md
is the narrative version). Re-run whenever the catalog changes:

    .venv/bin/python scripts/audit-privileges.py

Classification:
  formula            -> never root (installs under /opt/homebrew, user-owned)
  cask app/binary    -> user-space IF brew targets a user-writable appdir
                        (e.g. --appdir=$HOME/Applications); the /Applications
                        default needs admin on standard-user Macs
  cask pkg/installer -> ROOT always (runs Apple's installer) -> system[]/MDM
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import load_all  # noqa: E402

ROOT_KINDS = {"pkg", "installer"}


def main():
    catalog, roles, _users = load_all()
    apps = catalog["apps"]
    formulae = sorted(k for k, v in apps.items() if v["source"] == "formula")
    casks = {k: v for k, v in apps.items() if v["source"] == "cask"}

    out = subprocess.run(
        ["brew", "info", "--json=v2", "--cask", *[v["id"] for v in casks.values()]],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"brew info failed (bad cask id in catalog?):\n{out.stderr.strip()}")
    by_token = {c["token"]: c for c in json.loads(out.stdout)["casks"]}

    user_space, needs_root = [], []
    for key, v in sorted(casks.items()):
        arts = set().union(*[set(a) for a in by_token[v["id"]].get("artifacts", [])])
        (needs_root if arts & ROOT_KINDS else user_space).append(
            (key, v["id"], ",".join(sorted(arts & {"app", "pkg", "installer", "binary"}))))

    holders = {k: sorted(r for r, role in roles.items() if k in (role.get("apps") or []))
               for k in apps}

    print(f"{len(apps)} apps = {len(formulae)} formulae · "
          f"{len(user_space)} user-space casks · {len(needs_root)} ROOT casks\n")
    print("== ROOT casks (pkg/installer — trust plane / system[] / MDM) ==")
    for key, cid, arts in needs_root:
        print(f"  {key:16} {cid:20} [{arts}]  roles: {', '.join(holders[key]) or '-'}")
    print("\n== user-space casks (app/binary — convenience plane w/ user appdir) ==")
    for key, cid, arts in user_space:
        print(f"  {key:16} {cid:20} [{arts}]")
    print("\n== formulae (never root) ==")
    print("  " + " ".join(formulae))


if __name__ == "__main__":
    main()
