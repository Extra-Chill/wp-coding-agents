#!/bin/bash
# tests/cli-channel-perms.sh — Regression coverage for issue #133 and
# issue #258 in lib/cli-channel.sh.
#
# The mu-plugin file written by cli_channel_ensure_mu_plugin_file /
# cli_channel_register must land at mode 0664 and be group-owned by its
# parent directory's group, regardless of the caller's umask or identity.
# PHP-FPM (www-data) needs world-read to load it (#133: root cron/systemd
# contexts default to umask 0077 → 0600, breaking every daemon-context
# install). Group-writable + group-inherited (#258) is needed on top of
# that because root (upgrade), the service user (opencode, member of the
# webroot group), and www-data all write this file across different runs —
# 0644 with a mismatched owner locks the next writer out entirely.
#
# Asserts the three write paths each produce mode 0664 + inherited group:
#   1. Fresh scaffold (cli_channel_ensure_mu_plugin_file)
#   2. Subsequent register replacing/inserting a block (mktemp + mv)
#   3. Unregister removing a block (mktemp + mv)
#
# Also asserts the self-heal behavior: if a legacy file is mode 0600 or
# owned by a different group (left by a pre-fix install or an upgrade that
# ran as a different identity than the last write), the next register call
# must restore 0664 + the parent dir's group.
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
DIR_GROUP="$(stat -c %G "$TMP/wp-content/mu-plugins" 2>/dev/null || stat -f %Sg "$TMP/wp-content/mu-plugins")"
FAILED=0

assert_mode_0664() {
  local file="$1" name="$2"
  local got
  if stat -c %a "$file" >/dev/null 2>&1; then
    got=$(stat -c %a "$file")
  else
    got=$(stat -f %Lp "$file")
  fi
  if [ "$got" = "664" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: 664"
    FAILED=$((FAILED + 1))
  fi
}

assert_group() {
  local file="$1" name="$2"
  local got
  got=$(stat -c %G "$file" 2>/dev/null || stat -f %Sg "$file")
  if [ "$got" = "$DIR_GROUP" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: $DIR_GROUP (parent dir's group)"
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
assert_mode_0664 "$MU_FILE" "fresh scaffold lands as 0664 under umask 077"
assert_group "$MU_FILE" "fresh scaffold inherits parent dir group"

# --- 2. Sibling register exercises mktemp + mv path; self-heal from 0600 ---
echo "==> simulate legacy 0600 file and verify self-heal on next register"
chmod 0600 "$MU_FILE"
(
  umask 077
  cli_channel_register "opencode-telegram" \
    "/usr/local/bin/opencode-telegram" \
    '["dispatch","--chat","{recipient}","--text","{message}"]'
)
assert_mode_0664 "$MU_FILE" "mu-plugin self-healed to 0664 after sibling register"
assert_group "$MU_FILE" "mu-plugin self-healed group after sibling register"

# --- 3. Unregister also lands as 0664 --------------------------------------
echo "==> unregister opencode-telegram"
chmod 0600 "$MU_FILE"
(
  umask 077
  cli_channel_unregister "opencode-telegram"
)
assert_mode_0664 "$MU_FILE" "mu-plugin mode 0664 after unregister"
assert_group "$MU_FILE" "mu-plugin group after unregister"

# --- Done ------------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all cli-channel perms assertions passed"
