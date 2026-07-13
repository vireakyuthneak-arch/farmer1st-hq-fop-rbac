#!/bin/bash
# catalog-add.sh — auto-generate a catalog entry by asking Homebrew.
#
# Instead of hand-writing name/source/id, give it a brew token and it queries
# `brew info`, figures out formula vs cask + the display name, and appends a
# correct entry to fop/catalog.yml. Optionally also adds the key to a role.
#
# Usage:
#   bash scripts/catalog-add.sh rectangle                    # add to catalog
#   bash scripts/catalog-add.sh notion --role devops-engineer
#   bash scripts/catalog-add.sh docker --formula             # disambiguate
#   bash scripts/catalog-add.sh figma --version "1.2.3"      # pin a version
#   bash scripts/catalog-add.sh trello --dry-run             # show, don't write
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/fop/catalog.yml"
ROLES_DIR="$ROOT/fop/roles"

TOKEN=""; KIND=""; ROLE=""; CATEGORY="uncategorized"; VERSION="latest"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cask) KIND="cask" ;;
    --formula) KIND="formula" ;;
    --role) ROLE="$2"; shift ;;
    --category) CATEGORY="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) TOKEN="$1" ;;
  esac; shift
done
[ -n "$TOKEN" ] || { echo "usage: catalog-add.sh <brew-token> [--cask|--formula] [--role R] [--category C] [--version V] [--dry-run]" >&2; exit 2; }
command -v brew >/dev/null || { echo "Homebrew required" >&2; exit 1; }

if grep -qE "^  ${TOKEN}:[ \t]*$" "$CATALOG"; then
  echo "'$TOKEN' is already in the catalog — nothing to do."; exit 0
fi

# Ask Homebrew what this token is. A name can exist as BOTH a formula and a
# cask, and `brew info --json=v2 <name>` returns only the formula in that case —
# so query each kind separately and merge. (brew JSON goes to temp files; the
# heredoc is Python's program on stdin, so data must come via file args.)
F_FILE="$(mktemp)"; C_FILE="$(mktemp)"
trap 'rm -f "$F_FILE" "$C_FILE"' EXIT
brew info --json=v2 --formula "$TOKEN" 2>/dev/null > "$F_FILE"
brew info --json=v2 --cask "$TOKEN" 2>/dev/null > "$C_FILE"
parsed="$(KIND="$KIND" python3 - "$TOKEN" "$F_FILE" "$C_FILE" <<'PY'
import json, os, sys
tok = sys.argv[1]; want = os.environ.get("KIND", "")
def load(path, key):
    try:
        with open(path) as fh:
            return json.loads(fh.read() or "{}").get(key) or []
    except Exception:
        return []
formulae = load(sys.argv[2], "formulae")
casks = load(sys.argv[3], "casks")
def emit(kind, name, ident): print(f"{kind}\t{name}\t{ident}")
if want == "cask" and casks:
    c = casks[0]; emit("cask", (c.get("name") or [tok])[0], c["token"])
elif want == "formula" and formulae:
    f = formulae[0]; emit("formula", f["name"], f["name"])
elif casks and formulae:
    print("AMBIGUOUS")
elif casks:
    c = casks[0]; emit("cask", (c.get("name") or [tok])[0], c["token"])
elif formulae:
    f = formulae[0]; emit("formula", f["name"], f["name"])
else:
    print("NOTFOUND")
PY
)"

case "$parsed" in
  NOTFOUND|"")
    echo "'$TOKEN' is not a Homebrew formula or cask."
    echo "It may be Mac App Store only (like Trello). Add it manually as:"
    echo "  ${TOKEN}:"
    echo "    name: ${TOKEN}"
    echo "    source: mas"
    echo "    id: \"<app-store-id>\"   # find with: mas search ${TOKEN}"
    echo "    version: latest"
    echo "    category: ${CATEGORY}"
    exit 1 ;;
  AMBIGUOUS)
    echo "'$TOKEN' exists as BOTH a formula and a cask — rerun with --formula or --cask." >&2
    exit 1 ;;
esac

SRC="$(printf '%s' "$parsed" | cut -f1)"
NAME="$(printf '%s' "$parsed" | cut -f2)"
ID="$(printf '%s' "$parsed" | cut -f3)"

if [ "$VERSION" = "latest" ]; then VER_FIELD="latest"; else VER_FIELD="\"${VERSION}\""; fi
ENTRY="  ${TOKEN}:
    name: \"${NAME}\"
    source: ${SRC}
    id: ${ID}
    version: ${VER_FIELD}
    category: ${CATEGORY}"

echo "Generated catalog entry:"
echo "$ENTRY"
echo ""

if [ "$DRY" = 1 ]; then echo "(dry-run — nothing written)"; exit 0; fi

printf '%s\n' "$ENTRY" >> "$CATALOG"
echo "-> appended to fop/catalog.yml"

if [ -n "$ROLE" ]; then
  RF="$ROLES_DIR/${ROLE%.yml}.yml"
  [ -f "$RF" ] || { echo "role '$ROLE' not found; skipped role edit" >&2; exit 1; }
  tmp="$(mktemp)"
  awk -v k="$TOKEN" '{print} /^apps:/{print "  - " k}' "$RF" > "$tmp" && mv "$tmp" "$RF"
  echo "-> added '$TOKEN' to role $ROLE"
fi

echo "Run 'make validate' to confirm."
