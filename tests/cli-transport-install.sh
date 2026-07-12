#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/wp-content/mu-plugins"
export SITE_PATH="$TMP"
export DRY_RUN=false

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cli-transport.sh"
UPDATED_ITEMS=()

log() { :; }
warn() { echo "WARN: $1" >&2; }

MU_FILE="$TMP/wp-content/mu-plugins/wp-coding-agents-cli-transport.php"
FAILED=0

assert_mode_0664() {
  local got
  if stat -c %a "$MU_FILE" >/dev/null 2>&1; then
    got=$(stat -c %a "$MU_FILE")
  else
    got=$(stat -f %Lp "$MU_FILE")
  fi
  if [ "$got" = "664" ]; then
    echo "  ok   transport mu-plugin mode 0664"
  else
    echo "  FAIL transport mu-plugin mode got $got, want 664"
    FAILED=$((FAILED + 1))
  fi
}

assert_group() {
  local got want
  got=$(stat -c %G "$MU_FILE" 2>/dev/null || stat -f %Sg "$MU_FILE")
  want=$(stat -c %G "$(dirname "$MU_FILE")" 2>/dev/null || stat -f %Sg "$(dirname "$MU_FILE")")
  if [ "$got" = "$want" ]; then
    echo "  ok   transport mu-plugin group matches parent dir ($want)"
  else
    echo "  FAIL transport mu-plugin group got $got, want $want (parent dir's group)"
    FAILED=$((FAILED + 1))
  fi
}

(
  umask 077
  cli_transport_install
)

if [ ! -f "$MU_FILE" ]; then
  echo "  FAIL transport mu-plugin was not written"
  FAILED=$((FAILED + 1))
else
  echo "  ok   transport mu-plugin written"
fi

if ! cmp -s "$SCRIPT_DIR/templates/wp-coding-agents-cli-transport.php" "$MU_FILE"; then
  echo "  FAIL transport mu-plugin does not match template"
  FAILED=$((FAILED + 1))
else
  echo "  ok   transport mu-plugin matches template"
fi

assert_mode_0664
assert_group

# Legacy-mode self-heal: content unchanged, mode drifted back to 0600.
chmod 0600 "$MU_FILE"
cli_transport_install
assert_mode_0664
assert_group

# Live-bug regression (see issue #258): content unchanged but a *different*
# writer identity left the file with mismatched ownership (observed live:
# root:www-data / opencode:www-data / www-data:www-data across 4 sibling
# mu-plugins from the same installer, none group-writable). The
# content-unchanged short-circuit in cli_transport_install must still
# normalize mode/group, not just skip out early once cmp -s matches.
chmod 0644 "$MU_FILE"
cli_transport_install
assert_mode_0664
assert_group

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo "OK: CLI transport install assertions passed"
