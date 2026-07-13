#!/bin/bash
# abra.sh — a minimal, standalone stand-in for Abra.
#
# Identifies THIS Mac and converges it to the right apps with no arguments: it
# reads the machine's hardware serial, finds the user in the RBEC whose devices
# list that serial, resolves their role(s) + overrides into an app set, and
# brings each app to the desired state via Homebrew / mas. NOT the real Abra
# (that's a separate, always-on service). Runs on macOS's stock bash 3.2.
#
# Convergence per app (idempotent):
#   not installed              -> install
#   installed and current      -> skip
#   installed but outdated     -> upgrade   (only when version: latest)
#   pinned version             -> ensure installed, never force-upgrade
#   present but not via brew    -> skip (don't duplicate a manual install)
#
# Usage:
#   bash scripts/abra.sh                 # auto-detect this Mac -> its user -> role apps
#   bash scripts/abra.sh --dry-run       # show what it WOULD do
#   bash scripts/abra.sh --serial XXXX   # pretend to be another Mac (testing)
#   bash scripts/abra.sh --user yuthneak    # force a user (testing)
#   bash scripts/abra.sh --role backend-engineer   # force a role, skip lookup
#
# Casks install into ~/Applications so no admin password is needed. mas apps
# require being signed into the App Store; direct downloads are reported only.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/fop/catalog.yml"
USERS_DIR="$ROOT/fop/users"
ROLES_DIR="$ROOT/fop/roles"

DRY_RUN=0; FORCE_SERIAL=""; FORCE_USER=""; FORCE_ROLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --serial)  FORCE_SERIAL="$2"; shift ;;
    --user)    FORCE_USER="$2"; shift ;;
    --role)    FORCE_ROLE="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$CATALOG" ] || { echo "catalog not found: $CATALOG" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required (https://brew.sh)" >&2; exit 1; }

# --- yaml helpers (structure-specific; bash 3.2 safe) ---
yaml_top_list() { # file key
  awk -v key="$2" '
    $0 ~ "^"key":" { inl=1
      if ($0 ~ /\[/) { l=$0; sub(/.*\[/,"",l); sub(/\].*/,"",l); n=split(l,a,","); for(i=1;i<=n;i++){gsub(/[ \t]/,"",a[i]); if(a[i]!="")print a[i]} inl=0 }
      next }
    inl && /^[A-Za-z]/ { inl=0 }
    inl && /^[ \t]*-[ \t]*/ { v=$0; sub(/^[ \t]*-[ \t]*/,"",v); gsub(/[ \t]/,"",v); print v }
  ' "$1"
}
override_list() { # file which
  awk -v which="$2" '
    /^overrides:/ { ov=1; next }
    ov && /^[A-Za-z]/ { ov=0 }
    ov && $0 ~ "^  "which":" { m=1
      if ($0 ~ /\[/) { l=$0; sub(/.*\[/,"",l); sub(/\].*/,"",l); n=split(l,a,","); for(i=1;i<=n;i++){gsub(/[ \t]/,"",a[i]); if(a[i]!="")print a[i]} m=0 }
      next }
    ov && m && /^  [A-Za-z]/ { m=0 }
    ov && m && /^[ \t]*-[ \t]*/ { v=$0; sub(/^[ \t]*-[ \t]*/,"",v); gsub(/[ \t]/,"",v); print v }
  ' "$1"
}
# Resolve one catalog key -> "source<TAB>id<TAB>version<TAB>name".
lookup() { # key
  awk -v want="$1" '
    /^  [A-Za-z0-9_-]+:[ \t]*$/ { k=$1; sub(/:$/,"",k); cur=(k==want); s=""; id=""; ver=""; nm=""; next }
    cur && /^    name:/ { $1=""; v=$0; sub(/^[ \t]+/,"",v); sub(/[ \t]*#.*$/,"",v); gsub(/"/,"",v); sub(/[ \t]+$/,"",v); nm=v }
    cur && /^    source:/ { s=$2 }
    cur && /^    id:/ { $1=""; v=$0; sub(/^[ \t]+/,"",v); sub(/[ \t]*#.*$/,"",v); gsub(/"/,"",v); sub(/[ \t]+$/,"",v); id=v }
    cur && /^    version:/ { ver=$2; gsub(/"/,"",ver) }
    cur && /^    category:/ { print s"\t"id"\t"ver"\t"nm; cur=0 }
  ' "$CATALOG"
}
detect_serial() { system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2; exit}'; }

# --- installed-state probes ---
formula_installed() { brew list --formula --versions "$1" >/dev/null 2>&1; }
cask_installed()    { brew list --cask "$1" >/dev/null 2>&1; }
formula_outdated()  { brew outdated --formula "$1" 2>/dev/null | grep -q .; }
cask_outdated()     { brew outdated --cask "$1" 2>/dev/null | grep -q .; }
mas_installed()     { mas list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
# True if an app bundle with this display name exists (covers preinstalled or
# manually installed App Store apps without touching mas at all).
app_bundle_present() { [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]; }
# True if a cask's app bundle already exists on disk (installed outside brew).
cask_app_present() {
  local app
  app="$(brew info --cask "$1" 2>/dev/null | awk -F' \\(App\\)' '/\(App\)/{print $1; exit}')"
  [ -n "$app" ] || return 1
  [ -d "/Applications/$app" ] || [ -d "$HOME/Applications/$app" ]
}

# --- figure out which role(s) apply to this machine ---
declare_roles=""; USERFILE=""
if [ -n "$FORCE_ROLE" ]; then
  declare_roles="$FORCE_ROLE"
  echo ""; echo "abra.sh — forced role: $FORCE_ROLE$([ "$DRY_RUN" = 1 ] && echo '   [dry-run]')"
else
  if [ -n "$FORCE_USER" ]; then
    USERFILE="$USERS_DIR/${FORCE_USER}.yml"
    [ -f "$USERFILE" ] || { echo "no such user: $FORCE_USER" >&2; exit 1; }
    SERIAL="(forced user)"
  else
    SERIAL="${FORCE_SERIAL:-$(detect_serial)}"
    [ -n "$SERIAL" ] || { echo "could not read this Mac's serial" >&2; exit 1; }
    USERFILE="$(grep -rl "serial: *$SERIAL\b" "$USERS_DIR" 2>/dev/null | head -1)"
    if [ -z "$USERFILE" ]; then
      # Per the Abra contract: an unassigned Mac is outside the fleet, not an
      # error — log and exit cleanly so heartbeat runners don't alarm.
      echo "This Mac (serial $SERIAL) is not assigned to anyone in the RBEC — nothing to do."
      exit 0
    fi
  fi
  who="$(basename "$USERFILE" .yml)"
  declare_roles="$(yaml_top_list "$USERFILE" roles | tr '\n' ' ')"
  echo ""; echo "abra.sh$([ "$DRY_RUN" = 1 ] && echo '   [dry-run]')"
  echo "machine serial : $SERIAL"
  echo "resolved user  : $who"
  echo "roles          : $declare_roles"
fi
echo ""

# --- build the desired app-key set: role apps (union) + overrides ---
desired=""
add_key() { case " $desired " in *" $1 "*) ;; *) desired="$desired $1" ;; esac; }
del_key() { desired=" $(echo " $desired " | sed "s/ $1 / /g") "; }
for role in $declare_roles; do
  rf="$ROLES_DIR/${role}.yml"
  [ -f "$rf" ] || { echo "  ! role '$role' has no file, skipping"; continue; }
  for app in $(yaml_top_list "$rf" apps); do add_key "$app"; done
done
if [ -n "$USERFILE" ]; then
  for app in $(override_list "$USERFILE" add); do add_key "$app"; done
  for app in $(override_list "$USERFILE" remove); do del_key "$app"; done
fi

# --- converge ---
inst=0; upg=0; skip=0; fail=0
mkdir -p "$HOME/Applications"

run() { # action-verb  command...
  local verb="$1"; shift
  echo "  -> $KEY ($SRC @$VER): $verb"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    case "$verb" in install) inst=$((inst+1));; upgrade) upg=$((upg+1));; esac
    echo "     done"
  else
    fail=$((fail+1))
    echo "     FAILED (exit $rc): $*"
    printf '%s\n' "$out" | tail -n 12 | sed 's/^/       | /'
  fi
}
report_skip() { echo "  .. $KEY ($SRC @$VER): $1"; skip=$((skip+1)); }

for KEY in $desired; do
  line="$(lookup "$KEY")"
  SRC="$(printf '%s' "$line" | cut -f1)"
  id="$(printf '%s' "$line" | cut -f2)"
  VER="$(printf '%s' "$line" | cut -f3)"
  NAME="$(printf '%s' "$line" | cut -f4)"
  [ -n "$SRC" ] || { echo "  ! $KEY — not in catalog"; skip=$((skip+1)); continue; }

  case "$SRC" in
    formula)
      if formula_installed "$id"; then
        if [ "$VER" = "latest" ] && formula_outdated "$id"; then run upgrade brew upgrade --formula "$id"
        else report_skip "already installed"; fi
      else run install brew install --formula "$id"; fi ;;
    cask)
      if cask_installed "$id"; then
        if [ "$VER" = "latest" ] && cask_outdated "$id"; then run upgrade brew upgrade --cask "$id"
        else report_skip "already installed"; fi
      elif cask_app_present "$id"; then report_skip "already present (installed outside brew)"
      else run install brew install --cask --adopt --appdir="$HOME/Applications" "$id"; fi ;;
    mas)
      # Never auto-install from the App Store: mas needs a signed-in Apple
      # account and can trigger admin prompts. Detect if present; else report.
      if mas_installed "$id" || app_bundle_present "$NAME"; then
        report_skip "already installed"
      else
        report_skip "App Store only — install once via App Store app or MDM (auto-install disabled)"
      fi ;;
    direct) report_skip "direct download — privileged plane" ;;
    *) echo "  ! $KEY — unknown source '$SRC'"; skip=$((skip+1)) ;;
  esac
done

echo ""
echo "done — $inst installed, $upg upgraded, $skip skipped, $fail failed"
