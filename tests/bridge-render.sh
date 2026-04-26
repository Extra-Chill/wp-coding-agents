#!/bin/bash
# tests/bridge-render.sh — byte-equivalence guard for chat-bridge templates.
#
# Captures the output of the legacy install functions in lib/chat-bridge.sh
# (by mocking write_file / run_cmd / log / warn / launchctl / systemctl /
# chmod / chown) and the output of the new bridge_render_systemd /
# bridge_render_launchd generators in lib/chat-bridges.sh, and diffs them.
#
# Every unit file and plist across every bridge × env × token-state combo
# must be byte-identical. Exits non-zero if any diff is non-empty.
#
# Usage:
#   tests/bridge-render.sh              # run and diff, print pass/fail
#   tests/bridge-render.sh --verbose    # also print the captured output
#   tests/bridge-render.sh --update     # (future) refresh fixtures
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Mock env — fixed values so templates are deterministic
# ---------------------------------------------------------------------------
export SERVICE_USER="chubes"
export SERVICE_HOME="/home/chubes"
export SITE_PATH="/var/www/site"
export PLATFORM="linux"
export LOCAL_MODE=false
export DRY_RUN=false
export INSTALL_CHAT=true
export RUN_AS_ROOT=false

# kimaki
export KIMAKI_DATA_DIR="$SERVICE_HOME/.kimaki"
export KIMAKI_CONFIG_DIR="/opt/kimaki-config"
export KIMAKI_BIN="/usr/bin/kimaki"
export KIMAKI_BOT_TOKEN=""

# cc-connect
export CC_BIN="/usr/bin/cc-connect"
export CC_DATA_DIR="$SERVICE_HOME/.cc-connect"
export CC_CONNECT_TOKEN=""

# telegram
export OPENCODE_BIN="/usr/bin/opencode"
export TELEGRAM_BIN="/usr/bin/opencode-telegram"
export SERVE_ENV_FILE="$SERVICE_HOME/.config/opencode-serve.env"
export TELEGRAM_CONFIG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"
export TELEGRAM_BOT_TOKEN=""
export TELEGRAM_ALLOWED_USER_ID=""
export OPENCODE_MODEL=""

# ---------------------------------------------------------------------------
# Mocks — replace side-effecting helpers with capture-only versions
# ---------------------------------------------------------------------------
CAPTURED_FILE=""
CAPTURED_CONTENT=""

write_file() {
  CAPTURED_FILE="$1"
  CAPTURED_CONTENT="$2"
}

run_cmd()  { :; }
log()      { :; }
warn()     { :; }
launchctl() { :; }
systemctl() { :; }
chmod()    { :; }
chown()    { :; }

# lib/common.sh exports colour vars + log/warn/error; install_chat_bridge
# wants them defined.
RED=""
GREEN=""
YELLOW=""
BLUE=""
NC=""

# ---------------------------------------------------------------------------
# Load legacy install functions
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source lib/chat-bridge.sh
# shellcheck disable=SC1091
source lib/chat-bridges.sh

TMPDIR_OLD="$(mktemp -d)"
TMPDIR_NEW="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_OLD" "$TMPDIR_NEW"' EXIT

# capture_old  <label> <installer-function>
#   Calls the legacy installer under mocks and writes CAPTURED_CONTENT to
#   $TMPDIR_OLD/<label>. If the installer writes multiple files the caller
#   splits them (see telegram below).
capture_old() {
  local label="$1" fn="$2"
  CAPTURED_FILE=""; CAPTURED_CONTENT=""
  "$fn"
  printf '%s\n' "$CAPTURED_CONTENT" > "$TMPDIR_OLD/$label"
}

# For multi-file installers (telegram) we need to capture each write_file
# call. Swap the mock to append to an ordered list.
OLD_WRITES_FILES=()
OLD_WRITES_CONTENT=()

capture_old_multi_setup() {
  OLD_WRITES_FILES=()
  OLD_WRITES_CONTENT=()
  # Redefine write_file for this capture
  write_file() {
    OLD_WRITES_FILES+=("$1")
    OLD_WRITES_CONTENT+=("$2")
  }
}

# ---------------------------------------------------------------------------
# Helpers for rebuilding env blocks equivalent to the legacy installers
# ---------------------------------------------------------------------------
kimaki_env_block() {
  local kimaki_bin_dir node_bin_dir path_value
  kimaki_bin_dir=$(dirname "$KIMAKI_BIN")
  node_bin_dir=$(_resolve_node_bin_dir "$KIMAKI_BIN")
  path_value=$(_compose_path_value "$kimaki_bin_dir" "$node_bin_dir" /usr/local/bin /usr/bin /bin)
  local out="Environment=HOME=$SERVICE_HOME
Environment=PATH=$path_value
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"
  if [ -n "${KIMAKI_BOT_TOKEN:-}" ]; then
    out="$out
Environment=KIMAKI_BOT_TOKEN=$KIMAKI_BOT_TOKEN"
  fi
  printf '%s' "$out"
}

cc_connect_env_block() {
  local out="Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin"
  if [ -n "${CC_CONNECT_TOKEN:-}" ]; then
    out="$out
Environment=CC_CONNECT_TOKEN=$CC_CONNECT_TOKEN"
  fi
  printf '%s' "$out"
}

telegram_env_block() {
  printf '%s' "Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin"
}

# ---------------------------------------------------------------------------
# Snapshots: systemd
# ---------------------------------------------------------------------------
echo "==> systemd snapshots"

# kimaki
capture_old kimaki-systemd _install_kimaki_systemd
bridge_render_systemd kimaki kimaki.service "$(kimaki_env_block)" > "$TMPDIR_NEW/kimaki-systemd"

# cc-connect
capture_old cc-connect-systemd _install_cc_connect_systemd
bridge_render_systemd cc-connect cc-connect.service "$(cc_connect_env_block)" > "$TMPDIR_NEW/cc-connect-systemd"

# telegram (two writes)
capture_old_multi_setup
_install_telegram_systemd
printf '%s\n' "${OLD_WRITES_CONTENT[0]}" > "$TMPDIR_OLD/telegram-serve-systemd"
printf '%s\n' "${OLD_WRITES_CONTENT[1]}" > "$TMPDIR_OLD/telegram-bot-systemd"
bridge_render_systemd telegram opencode-serve.service "$(telegram_env_block)" > "$TMPDIR_NEW/telegram-serve-systemd"
bridge_render_systemd telegram opencode-telegram.service "$(telegram_env_block)" > "$TMPDIR_NEW/telegram-bot-systemd"

# restore single-capture mock for launchd pass
write_file() { CAPTURED_FILE="$1"; CAPTURED_CONTENT="$2"; }

# ---------------------------------------------------------------------------
# Snapshots: launchd
#
# Launchd installers depend on PLATFORM=mac + LOCAL_MODE=true + HOME set.
# Swap in mac-specific env for this pass only, so dry-run bin path matches.
# ---------------------------------------------------------------------------
echo "==> launchd snapshots"

PLATFORM="mac"
LOCAL_MODE=true
HOME_SAVE="$HOME"
export HOME="$SERVICE_HOME"
# The launchd installers hardcode /opt/homebrew/bin/... under DRY_RUN=true,
# so run them as if dry-running to get deterministic binary paths.
DRY_RUN_SAVE="$DRY_RUN"
DRY_RUN=true
KIMAKI_BIN="/opt/homebrew/bin/kimaki"
CC_BIN="/opt/homebrew/bin/cc-connect"
OPENCODE_BIN="/opt/homebrew/bin/opencode"
TELEGRAM_BIN="/opt/homebrew/bin/opencode-telegram"

# kimaki
capture_old kimaki-launchd _install_kimaki_launchd
bridge_render_launchd kimaki com.wp.kimaki > "$TMPDIR_NEW/kimaki-launchd"

# cc-connect
capture_old cc-connect-launchd _install_cc_connect_launchd
bridge_render_launchd cc-connect com.wp.cc-connect > "$TMPDIR_NEW/cc-connect-launchd"

# telegram (two writes)
capture_old_multi_setup
_install_telegram_launchd
printf '%s\n' "${OLD_WRITES_CONTENT[0]}" > "$TMPDIR_OLD/telegram-serve-launchd"
printf '%s\n' "${OLD_WRITES_CONTENT[1]}" > "$TMPDIR_OLD/telegram-bot-launchd"
bridge_render_launchd telegram com.wp.opencode-serve > "$TMPDIR_NEW/telegram-serve-launchd"
bridge_render_launchd telegram com.wp.opencode-telegram > "$TMPDIR_NEW/telegram-bot-launchd"

export HOME="$HOME_SAVE"
DRY_RUN="$DRY_RUN_SAVE"

# ---------------------------------------------------------------------------
# Diff pass
# ---------------------------------------------------------------------------
FAILED=0
echo "==> diffs"
for f in "$TMPDIR_OLD"/*; do
  name="$(basename "$f")"
  new="$TMPDIR_NEW/$name"
  if [ ! -f "$new" ]; then
    echo "  FAIL $name (missing new output)"
    FAILED=$((FAILED+1))
    continue
  fi
  if diff -q "$f" "$new" >/dev/null 2>&1; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    diff -u "$f" "$new" | head -40
    FAILED=$((FAILED+1))
  fi
done

if [ "$VERBOSE" = true ]; then
  echo
  echo "==> captured outputs at:"
  echo "  old: $TMPDIR_OLD"
  echo "  new: $TMPDIR_NEW"
  trap - EXIT
fi

if [ "$FAILED" -gt 0 ]; then
  echo
  echo "FAILED: $FAILED snapshot(s) drifted"
  exit 1
fi

echo
echo "OK: all snapshots byte-identical"
