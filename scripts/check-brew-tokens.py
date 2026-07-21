#!/usr/bin/env python3
"""check-brew-tokens.py — verify every catalog brew token still exists upstream.

Brew tokens rot silently: upstream renames (linear-linear -> linear happened to
this very catalog) or disables formulae, and the first symptom is a daemon's
`brew bundle` failing in the field. This check catches it in CI instead.

Runs anywhere (ubuntu CI included): it queries the Homebrew JSON API over
HTTPS — never the brew binary. Tap-qualified ids (owner/tap/name) are checked
against the tap's GitHub repo raw content.

    python3 scripts/check-brew-tokens.py            # exit 1 on any dead token

Pass --api-dir <dir> with pre-downloaded formula.json/cask.json to skip the
two bulk downloads (what the CI workflow does, for retry control).
"""
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import load_all  # noqa: E402

API = "https://formulae.brew.sh/api"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "fop-rbac-catalog-check"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main() -> int:
    api_dir = None
    if len(sys.argv) == 3 and sys.argv[1] == "--api-dir":
        api_dir = Path(sys.argv[2])

    catalog, _roles, _users = load_all()
    apps = catalog.get("apps") or {}

    if api_dir:
        formulae = json.loads((api_dir / "formula.json").read_bytes())
        casks = json.loads((api_dir / "cask.json").read_bytes())
    else:
        formulae = json.loads(fetch(f"{API}/formula.json"))
        casks = json.loads(fetch(f"{API}/cask.json"))

    # name + aliases for formulae; token + old_tokens for casks — so a rename
    # upstream is reported even while an alias still resolves.
    formula_names = {f["name"] for f in formulae}
    formula_alias = {a for f in formulae for a in (f.get("aliases") or [])}
    cask_tokens = {c["token"] for c in casks}
    cask_old = {t for c in casks for t in (c.get("old_tokens") or [])}
    disabled = {f["name"] for f in formulae if f.get("disabled")} | \
               {c["token"] for c in casks if c.get("disabled")}

    dead, renamed, off = [], [], []
    for key, app in sorted(apps.items()):
        tok, src = app["id"], app["source"]
        if "/" in tok:  # tap-qualified: check the tap repo directly
            owner, tap, name = tok.split("/", 2)
            url = (f"https://raw.githubusercontent.com/{owner}/homebrew-{tap}"
                   f"/HEAD/Formula/{name}.rb")
            try:
                fetch(url)
            except Exception:
                dead.append(f"  {key}: tap formula '{tok}' not found at {url}")
            continue
        live = formula_names if src == "formula" else cask_tokens
        old = formula_alias if src == "formula" else cask_old
        if tok in disabled:
            off.append(f"  {key}: {src} '{tok}' is DISABLED upstream (will stop installing)")
        elif tok in live:
            pass
        elif tok in old:
            renamed.append(f"  {key}: {src} '{tok}' was RENAMED upstream — update the catalog id")
        else:
            dead.append(f"  {key}: {src} '{tok}' does not exist in the Homebrew API")

    for title, rows in (("DEAD tokens", dead), ("RENAMED tokens", renamed),
                        ("DISABLED tokens", off)):
        if rows:
            print(f"{title}:\n" + "\n".join(rows))
    if dead or renamed or off:
        return 1
    print(f"catalog OK — all {len(apps)} brew tokens exist upstream")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
