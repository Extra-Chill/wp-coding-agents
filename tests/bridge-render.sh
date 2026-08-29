#!/bin/bash
# tests/bridge-render.sh — golden-file regression for chat-bridge templates.
#
# Renders every (bridge × unit / launchd-label × token-state) combo through
# the bridges/<name>.sh::bridge_render_systemd / bridge_render_launchd hooks
# and diffs against committed fixtures under tests/__snapshots__/bridges/.
#
# Pre-refactor (Extra-Chill/wp-coding-agents#76) this test diffed the legacy
# install functions in `lib/chat-bridge.sh` against the new generators in
# `lib/chat-bridges.sh`. Both files are gone; render is now the single source
# of truth and snapshots are the regression contract. Bridge edits that
# change the unit / plist text fail here loudly.
#
# Usage:
#   tests/bridge-render.sh              # diff all snapshots, print pass/fail
#   tests/bridge-render.sh --update     # rewrite snapshots from current output
#   tests/bridge-render.sh --verbose    # print each rendered file before diff
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib/common.sh"

UPDATE=false
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --update)  UPDATE=true ;;
    --verbose) VERBOSE=true ;;
  esac
done

SNAPSHOT_DIR="$SCRIPT_DIR/tests/__snapshots__/bridges"
mkdir -p "$SNAPSHOT_DIR"

# ---------------------------------------------------------------------------
# Mock env — fixed values so templates are deterministic. Kept identical to
# the pre-refactor test so existing snapshots stay valid.
#
# CRITICAL: PATH is sanitized to a minimal, machine-independent set so that
# `_resolve_node_bin_dir`'s `command -v node` probe and the kimaki-shim
# fallback both miss. KIMAKI_BIN points at a path that does not exist on
# any normal machine for the same reason. Without this, the kimaki snapshot
# leaks the dev machine's actual node / kimaki shim paths into the rendered
# Environment=PATH= line, and CI (which has neither) fails the diff.
# Snapshot files under tests/__snapshots__/bridges/ are the contract; this
# block is what makes the contract reproducible everywhere.
# ---------------------------------------------------------------------------
export PATH="/usr/bin:/bin"
export SERVICE_USER="chubes"
export SERVICE_HOME="/home/chubes"
export SITE_PATH="/var/www/site"
export PLATFORM="linux"
export LOCAL_MODE=false
export DRY_RUN=false
export INSTALL_CHAT=true
export RUN_AS_ROOT=false
export IS_STUDIO=false
export WP_CMD="wp"
export AGENT_SLUG="intelligence-chubes4"
export KIMAKI_LOCK_PORT=""

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
# Helpers — env blocks identical to what the legacy install functions used to
# build, so systemd snapshots stay byte-identical to pre-refactor output.
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/bridges/_dispatch.sh"

# Keep snapshots independent of whether the host happens to ship node in
# /usr/bin; node-path resolution has dedicated coverage in path-helpers.sh.
_resolve_node_bin_dir() { printf ''; }

REDACTED_DIFF=$(printf '%s\n' ' Environment=KIMAKI_BOT_TOKEN=secret-token' '         <key>KIMAKI_BOT_TOKEN</key>' '         <string>secret-token</string>' | _redact_secret_diff)
if echo "$REDACTED_DIFF" | grep -q 'secret-token'; then
  echo "FAIL: bridge diff redaction leaked a token"
  exit 1
fi

kimaki_env_block() {
  local kimaki_bin_dir node_bin_dir path_value
  kimaki_bin_dir=$(dirname "$KIMAKI_BIN")
  node_bin_dir=$(_resolve_node_bin_dir "$KIMAKI_BIN")
  path_value=$(_compose_path_value "$kimaki_bin_dir" "$node_bin_dir" /usr/local/bin /usr/bin /bin)
  local out="Environment=HOME=$SERVICE_HOME
Environment=PATH=$path_value
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR
Environment=DATAMACHINE_SITE_PATH=$SITE_PATH
Environment=DATAMACHINE_WP_CMD=$WP_CMD
Environment=DATAMACHINE_AGENT_SLUG=$AGENT_SLUG"
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

# render_with_bridge <bridge> <hook> [args...]
#
# Loads the bridge in a subshell and invokes its render hook. Subshell keeps
# the rendered files isolated — sourcing kimaki.sh defines bridge_render_*,
# loading cc-connect.sh into the same shell would clobber them.
render_with_bridge() {
  local bridge="$1" hook="$2"
  shift 2
  bridge_call "$bridge" "$hook" "$@"
}

TMPDIR_NEW="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_NEW"' EXIT

# ---------------------------------------------------------------------------
# Render every snapshot
# ---------------------------------------------------------------------------
echo "==> rendering snapshots"

# systemd ---------------------------------------------------------------
render_with_bridge kimaki     render_systemd kimaki.service           "$(kimaki_env_block)"     > "$TMPDIR_NEW/kimaki-systemd"
render_with_bridge cc-connect render_systemd cc-connect.service       "$(cc_connect_env_block)" > "$TMPDIR_NEW/cc-connect-systemd"
render_with_bridge telegram   render_systemd opencode-serve.service   "$(telegram_env_block)"   > "$TMPDIR_NEW/telegram-serve-systemd"
render_with_bridge telegram   render_systemd opencode-telegram.service "$(telegram_env_block)" > "$TMPDIR_NEW/telegram-bot-systemd"

# launchd ---------------------------------------------------------------
# Mac context: launchd binaries live under /opt/homebrew/bin per legacy test.
PLATFORM="mac"
LOCAL_MODE=true
HOME_SAVE="$HOME"
export HOME="$SERVICE_HOME"
KIMAKI_BIN="/opt/homebrew/bin/kimaki"
CC_BIN="/opt/homebrew/bin/cc-connect"
OPENCODE_BIN="/opt/homebrew/bin/opencode"
TELEGRAM_BIN="/opt/homebrew/bin/opencode-telegram"

render_with_bridge kimaki     render_launchd com.wp.kimaki            > "$TMPDIR_NEW/kimaki-launchd"
render_with_bridge cc-connect render_launchd com.wp.cc-connect        > "$TMPDIR_NEW/cc-connect-launchd"
render_with_bridge telegram   render_launchd com.wp.opencode-serve    > "$TMPDIR_NEW/telegram-serve-launchd"
render_with_bridge telegram   render_launchd com.wp.opencode-telegram > "$TMPDIR_NEW/telegram-bot-launchd"

export HOME="$HOME_SAVE"

# ---------------------------------------------------------------------------
# Verbose dump
# ---------------------------------------------------------------------------
if [ "$VERBOSE" = true ]; then
  echo
  for f in "$TMPDIR_NEW"/*; do
    echo "===== $(basename "$f") ====="
    cat "$f"
    echo
  done
fi

# ---------------------------------------------------------------------------
# Update mode: copy renders into snapshot dir
# ---------------------------------------------------------------------------
if [ "$UPDATE" = true ]; then
  for f in "$TMPDIR_NEW"/*; do
    cp "$f" "$SNAPSHOT_DIR/$(basename "$f")"
  done
  echo "OK: snapshots refreshed in $SNAPSHOT_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Diff against committed snapshots
# ---------------------------------------------------------------------------
FAILED=0
echo "==> diffs"
for f in "$TMPDIR_NEW"/*; do
  name="$(basename "$f")"
  expected="$SNAPSHOT_DIR/$name"
  if [ ! -f "$expected" ]; then
    echo "  FAIL $name (missing snapshot — run with --update to create)"
    FAILED=$((FAILED+1))
    continue
  fi
  if diff -q "$expected" "$f" >/dev/null 2>&1; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    diff -u "$expected" "$f" | head -40
    FAILED=$((FAILED+1))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo
  echo "FAILED: $FAILED snapshot(s) drifted"
  echo "If the change is intentional, refresh fixtures with:"
  echo "  tests/bridge-render.sh --update"
  exit 1
fi

echo
echo "OK: all snapshots match"

# ---------------------------------------------------------------------------
echo "==> effective-prompt runner resolution"
# ---------------------------------------------------------------------------
#
# The harness imports dm-context-filter.ts directly. node cannot load
# TypeScript — it exits ERR_UNKNOWN_FILE_EXTENSION before rendering a single
# prompt — and the upgrade reported that crash as
# "dm-context-filter may be leaking banned phrases".
#
# It warned on every h44lacrosse.com upgrade while the filter was in fact clean
# (verified: OK — 2 scenarios, 0 leaks, under bun). An alarm that is always
# wrong is worse than silence, because it teaches everyone to scroll past the
# one time it is right.

_ep_probe() {
  # Args: PATH_DIR SERVICE_HOME HOME
  ( PATH="$1:/usr/bin:/bin"; SERVICE_HOME="$2"; HOME="$3"
    # Model a host with no bun anywhere; this box really does have /root/.bun.
    KIMAKI_BUN_FALLBACK_HOME="${4:-$3}"
    # shellcheck disable=SC1090
    eval "$(sed -n '/^_kimaki_effective_prompt_runner()/,/^}/p' "$SCRIPT_DIR/bridges/kimaki.sh")"
    _kimaki_effective_prompt_runner )
}

EPT="$(mktemp -d)"
trap 'rm -rf "$EPT"' EXIT
mkdir -p "$EPT/onpath" "$EPT/svc/.bun/bin" "$EPT/root/.bun/bin" "$EPT/empty"
printf '#!/bin/sh\n' > "$EPT/onpath/bun"; chmod +x "$EPT/onpath/bun"
printf '#!/bin/sh\n' > "$EPT/svc/.bun/bin/bun"; chmod +x "$EPT/svc/.bun/bin/bun"

got="$(_ep_probe "$EPT/onpath" "" "$EPT/empty" "$EPT/empty")"
[ -n "$got" ] && echo "  ok   prefers bun on PATH" || { echo "  FAIL bun on PATH not found"; FAILED=$((FAILED+1)); }

# A service-identity migration moves the toolchain: bun installed for one
# identity is not on the PATH of a shell running as another.
got="$(_ep_probe "$EPT/empty" "$EPT/svc" "$EPT/empty" "$EPT/empty")"
case "$got" in
  */svc/.bun/bin/bun) echo "  ok   falls back to the service home" ;;
  *) echo "  FAIL did not find bun under SERVICE_HOME (got: ${got:-none})"; FAILED=$((FAILED+1)) ;;
esac

# No TypeScript-capable runtime: must report nothing, so the caller can say
# "unverified" instead of alleging a leak.
got="$(_ep_probe "$EPT/empty" "$EPT/empty" "$EPT/empty" "$EPT/empty")"
[ -z "$got" ] && echo "  ok   reports nothing when no TS runtime exists" || { echo "  FAIL returned '$got'"; FAILED=$((FAILED+1)); }

# And the caller must distinguish the two.
kimaki_src="$(cat "$SCRIPT_DIR/bridges/kimaki.sh")"
case "$kimaki_src" in
  *"effective-prompt test SKIPPED"*) echo "  ok   a missing runtime is reported as skipped" ;;
  *) echo "  FAIL no skipped path — a crash would still be called a leak"; FAILED=$((FAILED+1)) ;;
esac
case "$kimaki_src" in
  *"not known to be leaking"*) echo "  ok   the skip message denies alleging a leak" ;;
  *) echo "  FAIL the skip message does not disclaim a leak"; FAILED=$((FAILED+1)) ;;
esac
# node must not be invoked against the TypeScript import at all.
case "$kimaki_src" in
  *'TEST_OUT=$(node "$TEST_SCRIPT"'*) echo "  FAIL still runs the harness under node"; FAILED=$((FAILED+1)) ;;
  *) echo "  ok   no longer runs the harness under node" ;;
esac
