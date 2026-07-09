#!/usr/bin/env python3
"""Abra simulator — demonstrates what the real Abra binary does with the RBEC.

This is NOT Abra (that's built separately). It's a dry-run demo that mirrors
Abra's convergence loop so you can see the RBEC drive a Mac:

  1. a heartbeat fires with the Mac's serial
  2. resolve serial -> user -> role(s) -> desired app set (with overrides)
  3. diff against what's "installed" (a local simulated state file)
  4. print the exact brew/mas/direct commands to install missing apps and reap
     de-entitled ones — then record the new state

Run it repeatedly to simulate successive heartbeats: the first tick installs,
the next is a no-op, and editing the RBEC makes the following tick install/reap.
It NEVER touches Homebrew or your Mac — every command is printed, not executed.

Usage:
  python3 scripts/abra_sim.py --serial FCQN7GT76Y
  python3 scripts/abra_sim.py --user vireakyuth
  python3 scripts/abra_sim.py --serial FCQN7GT76Y --reset   # forget state
"""
import argparse
import json
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import load_all  # noqa: E402

STATE_DIR = Path(__file__).resolve().parent.parent / ".abra-sim"


def resolve_user(users, ident_serial, ident_user):
    """Find the user by device serial (as Abra would, via MDM) or by handle."""
    if ident_user:
        if ident_user not in users:
            sys.exit(f"unknown user '{ident_user}'")
        return ident_user, users[ident_user]
    for uname, u in users.items():
        for d in u.get("devices", []):
            if d.get("serial") == ident_serial:
                return uname, u
    sys.exit(f"no user in the RBEC owns device serial '{ident_serial}'")


def desired_apps(catalog, roles, user):
    """Role apps (union across roles) + overrides.add - overrides.remove."""
    keys = []
    for r in user["roles"]:
        for a in roles[r].get("apps", []):
            if a not in keys:
                keys.append(a)
    ov = user.get("overrides") or {}
    for a in ov.get("add") or []:
        if a not in keys:
            keys.append(a)
    for a in ov.get("remove") or []:
        if a in keys:
            keys.remove(a)
    return {k: catalog["apps"][k] for k in keys}


def install_cmd(app):
    src, ident = app["source"], app["id"]
    if src == "formula":
        return f"brew install {ident}"
    if src == "cask":
        return f"brew install --cask {ident}"
    if src == "mas":
        return f"mas install {ident}"
    if src == "direct":
        return f"curl -fsSLO {ident}  # verify sha256 then: sudo installer -pkg ... -target /"
    return f"# unknown source {src}"


def uninstall_cmd(app):
    src, ident = app["source"], app["id"]
    if src == "cask":
        return f"brew uninstall --cask {ident}"
    if src == "formula":
        return f"brew uninstall {ident}"
    if src == "mas":
        return f"# manually remove Mac App Store app {ident}"
    if src == "direct":
        return f"# run the vendor uninstaller for {ident}"
    return f"# unknown source {src}"


def run_step(cmd, app, apply):
    """Dry-run: return True so state updates as if it ran. Apply: actually run
    brew for formula/cask; skip mas/direct (need a GUI / vendor installer)."""
    if not apply:
        return True
    if app["source"] not in ("formula", "cask") or not cmd.startswith("brew "):
        print("      (skipped — --apply only executes brew formula/cask)")
        return False
    result = subprocess.run(shlex.split(cmd))
    if result.returncode != 0:
        print(f"      (brew exited {result.returncode} — left as-is)")
        return False
    return True


def load_state(path):
    if path.exists():
        return json.loads(path.read_text())
    return {"tick": 0, "installed": {}}


def save_state(path, state):
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--serial")
    g.add_argument("--user")
    ap.add_argument("--reset", action="store_true", help="forget simulated install state first")
    ap.add_argument("--apply", action="store_true",
                    help="ACTUALLY run brew for formula/cask apps (default is dry-run/print only)")
    args = ap.parse_args()

    catalog, roles, users = load_all()
    uname, user = resolve_user(users, args.serial, args.user)
    desired = desired_apps(catalog, roles, user)

    state_path = STATE_DIR / f"{uname}.json"
    if args.reset and state_path.exists():
        state_path.unlink()
    state = load_state(state_path)
    state["tick"] += 1
    installed = state["installed"]

    serial = args.serial or (user.get("devices") or [{}])[0].get("serial", "?")
    print(f"\n\033[1mabra • heartbeat tick #{state['tick']}\033[0m")
    print(f"device {serial}  ->  user {uname}  (roles: {', '.join(user['roles'])})")
    print(f"desired: {len(desired)} apps\n")

    to_install = {k: v for k, v in desired.items() if k not in installed}
    to_reap = {k: v for k, v in installed.items() if k not in desired}
    satisfied = [k for k in desired if k in installed]

    if not to_install and not to_reap:
        print("  \033[32mconverged\033[0m — nothing to do (no-op)")
        save_state(state_path, state)
        return 0

    if to_install:
        print(f"  install ({len(to_install)}):")
        for k, app in sorted(to_install.items()):
            cmd = install_cmd(app)
            print(f"    {cmd}")
            if run_step(cmd, app, args.apply):
                installed[k] = {"source": app["source"], "id": app["id"], "version": app.get("version")}
    if satisfied:
        print(f"\n  already satisfied ({len(satisfied)}): {', '.join(sorted(satisfied))}")
    if to_reap:
        print(f"\n  reap ({len(to_reap)}) — de-entitled:")
        for k, app in sorted(to_reap.items()):
            cmd = uninstall_cmd(app)
            print(f"    {cmd}")
            if run_step(cmd, app, args.apply):
                del installed[k]

    print(f"\n  \033[32mconverged\033[0m — {len(installed)} apps now on the Mac")
    save_state(state_path, state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
