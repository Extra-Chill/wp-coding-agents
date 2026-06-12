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

assert_mode_0644() {
  local got
  if stat -c %a "$MU_FILE" >/dev/null 2>&1; then
    got=$(stat -c %a "$MU_FILE")
  else
    got=$(stat -f %Lp "$MU_FILE")
  fi
  if [ "$got" = "644" ]; then
    echo "  ok   transport mu-plugin mode 0644"
  else
    echo "  FAIL transport mu-plugin mode got $got, want 644"
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

assert_mode_0644

chmod 0600 "$MU_FILE"
cli_transport_install
assert_mode_0644

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo "OK: CLI transport install assertions passed"
