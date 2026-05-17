#!/bin/bash
# tests/cli-channel-perms.sh — Regression coverage for issue #133 in
# lib/cli-channel.sh.
#
# The mu-plugin file written by cli_channel_ensure_mu_plugin_file /
# cli_channel_register must land at mode 0644 regardless of the caller's
# umask, because PHP-FPM (running as www-data) needs world-read to load it.
# Root cron/systemd contexts default to umask 0077 → 0600, which broke
# every install that ran setup.sh / upgrade.sh from a daemon context.
#
# Asserts the three write paths each produce mode 0644:
#   1. Fresh scaffold (cli_channel_ensure_mu_plugin_file)
#   2. Subsequent register replacing/inserting a block (mktemp + mv)
#   3. Unregister removing a block (mktemp + mv)
#
# Also asserts the self-heal behavior: if a legacy file is mode 0600
# (left by a pre-#133 install), the next register call must restore 0644.
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
source "$SCRIPT_DIR/lib/cli-channel.sh"
UPDATED_ITEMS=()

# Silence helper logs unless --verbose.
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
  esac
done
if [ "$VERBOSE" = false ]; then
  log() { :; }
  warn() { echo "WARN: $1" >&2; }
fi

MU_FILE="$TMP/wp-content/mu-plugins/wp-coding-agents-channels.php"
FAILED=0

assert_mode_0644() {
  local file="$1" name="$2"
  local got
  got=$(stat -c %a "$file")
  if [ "$got" = "644" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: 644"
    FAILED=$((FAILED + 1))
  fi
}

# --- 1. Fresh scaffold under hostile umask ---------------------------------
echo "==> register kimaki (fresh scaffold, umask 077)"
(
  umask 077
  cli_channel_register "kimaki" \
    "/usr/local/bin/kimaki" \
    '["send","--channel","{recipient}","--prompt","{message}"]'
)
assert_mode_0644 "$MU_FILE" "fresh scaffold lands as 0644 under umask 077"

# --- 2. Sibling register exercises mktemp + mv path; self-heal from 0600 ---
echo "==> simulate legacy 0600 file and verify self-heal on next register"
chmod 0600 "$MU_FILE"
(
  umask 077
  cli_channel_register "opencode-telegram" \
    "/usr/local/bin/opencode-telegram" \
    '["dispatch","--chat","{recipient}","--text","{message}"]'
)
assert_mode_0644 "$MU_FILE" "mu-plugin self-healed to 0644 after sibling register"

# --- 3. Unregister also lands as 0644 --------------------------------------
echo "==> unregister opencode-telegram"
chmod 0600 "$MU_FILE"
(
  umask 077
  cli_channel_unregister "opencode-telegram"
)
assert_mode_0644 "$MU_FILE" "mu-plugin mode 0644 after unregister"

# --- Done ------------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all cli-channel perms assertions passed"
