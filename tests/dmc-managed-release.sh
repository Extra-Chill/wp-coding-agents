#!/bin/bash
# Copied DMC stays Homeboy-owned. Git checkouts still update. Absent DMC can bootstrap.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/plugin-upgrade.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/data-machine.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
TIMESTAMP="test"
DRY_RUN=false
INSTALL_DATA_MACHINE=true
BLUE=""; NC=""
declare -a UPDATED_ITEMS=()
declare -a PENDING_ITEMS=()
declare -a PLUGIN_UPDATE_FAILURES=()
declare -a BOOTSTRAPS=()
LOG=""
log() { LOG="$LOG$*"$'\n'; }
warn() { LOG="$LOG$*"$'\n'; }
fix_ownership() { :; }
activate_plugin() { :; }
install_plugin_dependencies() { :; }
install_plugin_dependencies_bounded() { :; }
source_policy_workspace_enabled() { return 0; }
fail() { echo "FAIL: $1" >&2; exit 1; }

install_plugin() {
  local slug="$1" plugin_dir="$SITE_PATH/wp-content/plugins/$slug"
  mkdir -p "$plugin_dir"
  printf '<?php\n/*\n * Version: 9.9.9\n */\n' > "$plugin_dir/${slug}.php"
  git init "$plugin_dir" >/dev/null 2>&1
  BOOTSTRAPS+=("$slug")
}

fingerprint() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
digest = hashlib.sha256()
for dirpath, dirs, files in os.walk(root, followlinks=False):
    dirs.sort()
    files.sort()
    digest.update(os.path.relpath(dirpath, root).encode())
    for name in dirs + files:
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        digest.update(rel.encode())
        if os.path.islink(path):
            digest.update(b"link:")
            digest.update(os.readlink(path).encode())
        elif os.path.isfile(path):
            with open(path, "rb") as handle:
                digest.update(handle.read())
print(digest.hexdigest())
PY
}

mkdir -p "$SITE_PATH/wp-content/plugins/data-machine"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$SITE_PATH/wp-content/plugins/data-machine/data-machine.php"

PLUGIN="$SITE_PATH/wp-content/plugins/data-machine-code"
mkdir -p "$PLUGIN/inc"
printf '<?php\n/*\n * Version: 1.0.0\n */\n' > "$PLUGIN/data-machine-code.php"
printf 'homeboy-copied-bytes\n' > "$PLUGIN/inc/payload.txt"
printf 'direct-copy\n' > "$PLUGIN/HOMEBOY_DEPLOYED"
before="$(fingerprint "$PLUGIN")"

PLUGINS_ONLY=true
upgrade_data_machine_plugins
after="$(fingerprint "$PLUGIN")"
[ "$before" = "$after" ] || fail "copied DMC mutated during plugin-only upgrade"
[ ! -e "$PLUGIN/.wp-coding-agents-releases" ] || fail "copied DMC was converted to .wp-coding-agents-releases"
[ ! -e "$PLUGIN/.wp-coding-agents-release-current" ] || fail "copied DMC gained a release pointer"
[ ! -L "$PLUGIN/data-machine-code.php" ] || fail "copied DMC entrypoint was replaced with a loader"
[ -f "$PLUGIN/HOMEBOY_DEPLOYED" ] || fail "copied DMC layout lost Homeboy files"
case "$LOG" in *"Plugin data-machine-code is not a git checkout"*) : ;; *) fail "copied DMC did not keep the git-checkout skip path" ;; esac
[ "${#BOOTSTRAPS[@]}" -eq 0 ] || fail "copied DMC triggered bootstrap"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "copied DMC recorded an update"

git init "$PLUGIN" >/dev/null 2>&1
LOG=""
upgrade_data_machine_plugins
case "$LOG" in *"Plugin data-machine-code is not a git checkout"*) fail "git checkout used the copied skip path" ;; esac
[ ! -e "$PLUGIN/.wp-coding-agents-releases" ] || fail "git checkout was converted to .wp-coding-agents-releases"

rm -rf "$PLUGIN"
PLUGINS_ONLY=true
BOOTSTRAPS=()
LOG=""
upgrade_data_machine_plugins
[ "${#BOOTSTRAPS[@]}" -eq 0 ] || fail "plugin-only bootstrapped absent DMC"
case "$LOG" in *"not-installed"*) : ;; *) fail "plugin-only did not skip absent DMC" ;; esac

PLUGINS_ONLY=false
BOOTSTRAPS=()
upgrade_data_machine_plugins
[ "${#BOOTSTRAPS[@]}" -eq 1 ] || fail "absent DMC was not bootstrapped"
[ "${BOOTSTRAPS[0]}" = data-machine-code ] || fail "bootstrap targeted the wrong plugin"
[ -d "$PLUGIN/.git" ] || fail "bootstrap did not create a git checkout"
[ -f "$PLUGIN/data-machine-code.php" ] || fail "bootstrap did not install a plugin entrypoint"
[ ! -e "$PLUGIN/.wp-coding-agents-releases" ] || fail "bootstrap created .wp-coding-agents-releases"

echo "dmc-managed-release tests passed"
