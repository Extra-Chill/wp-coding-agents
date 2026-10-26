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

# Snapshots describe a host without a workspace data root; the operator shell may set one.
unset HOMEBOY_DATA_DIR
# Nor any Roadie service env (an agent shell under Roadie carries its own).
unset ROADIE_PI_MODEL ROADIE_PI_BIN ROADIE_POOL_URL ROADIE_CHANNELS_CONFIG

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"

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
# `_resolve_node_bin_dir`'s `command -v node` probe and the roadie-shim
# fallback both miss. ROADIE_BIN points at a path that does not exist on
# any normal machine for the same reason. Without this, the roadie snapshot
# leaks the dev machine's actual node / roadie shim paths into the rendered
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
export ROADIE_LOCK_PORT=""

# roadie
export ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
export ROADIE_SYSTEM_PREFIX="/usr/local/lib/wp-coding-agents/roadie"
export ROADIE_SECRETS_ROOT="/etc/wp-coding-agents"
export ROADIE_BIN="$ROADIE_SYSTEM_PREFIX/bin/roadie"
export ROADIE_BOT_TOKEN=""

# ---------------------------------------------------------------------------
# Helpers — env blocks identical to what the legacy install functions used to
# build, so systemd snapshots stay byte-identical to pre-refactor output.
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/bridges/_dispatch.sh"

# Keep snapshots independent of whether the host happens to ship node in
# /usr/bin; node-path resolution has dedicated coverage in path-helpers.sh.
_resolve_node_bin_dir() { printf ''; }

REDACTED_DIFF=$(printf '%s\n' ' Environment=ROADIE_BOT_TOKEN=secret-token' '         <key>ROADIE_BOT_TOKEN</key>' '         <string>secret-token</string>' | _redact_secret_diff)
if echo "$REDACTED_DIFF" | grep -q 'secret-token'; then
  echo "FAIL: bridge diff redaction leaked a token"
  exit 1
fi

# roadie_env_block — the env block a fresh systemd install writes, built by
# the bridge's own helpers so the snapshot tracks what actually ships.
roadie_env_block() {
  ( bridge_load roadie >/dev/null 2>&1
    _roadie_append_env_files "$(_roadie_template_env "$(_roadie_path_value)")" )
}

# render_with_bridge <bridge> <hook> [args...] — load the bridge in a subshell
# and invoke its render hook.
render_with_bridge() {
  local bridge="$1" hook="$2"
  shift 2
  bridge_call "$bridge" "$hook" "$@"
}

TMPDIR_NEW="$(mktemp -d)"
FIXTURE_HOST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_NEW" "$FIXTURE_HOST_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Hermetic host roots (#776) — the render probes the filesystem for optional
# host state (channels.yaml under the config root, bot-token / pool keys under
# the secrets root). On a managed host those files are REAL, so rendering
# against the default roots leaks extra Environment lines (e.g.
# ROADIE_CHANNELS_CONFIG) into output the committed snapshots never carry.
# Point every probed root at an empty fixture tree the test owns, then strip
# the fixture prefix from rendered output so snapshots keep the canonical
# host paths. The snapshot is now deterministic whether or not the host has
# a real /opt/roadie-config/channels.yaml or /etc/wp-coding-agents secrets.
# ---------------------------------------------------------------------------
mkdir -p "$FIXTURE_HOST_ROOT/opt/roadie-config" \
         "$FIXTURE_HOST_ROOT/etc/wp-coding-agents" \
         "$FIXTURE_HOST_ROOT$SERVICE_HOME/.roadie"
export ROADIE_CONFIG_DIR="$FIXTURE_HOST_ROOT/opt/roadie-config"
export ROADIE_SECRETS_ROOT="$FIXTURE_HOST_ROOT/etc/wp-coding-agents"
# Local-mode (launchd) probes live under ROADIE_DATA_DIR; redirect it too.
export ROADIE_DATA_DIR="$FIXTURE_HOST_ROOT$SERVICE_HOME/.roadie"

# strip_fixture_root — rewrite fixture paths back to the canonical host paths
# the committed snapshots use.
strip_fixture_root() { sed "s|$FIXTURE_HOST_ROOT||g"; }

# ---------------------------------------------------------------------------
# Render every snapshot
# ---------------------------------------------------------------------------
echo "==> rendering snapshots"

# systemd ---------------------------------------------------------------
render_with_bridge roadie render_systemd roadie.service "$(roadie_env_block)" | strip_fixture_root > "$TMPDIR_NEW/roadie-systemd"
if ! grep -Fq 'Environment=PATH=/usr/local/lib/wp-coding-agents/bin:/home/chubes/.local/bin:/home/chubes/.opencode/bin:/home/chubes/.local/share/pnpm:/home/chubes/.bun/bin:/usr/local/lib/wp-coding-agents/roadie/bin:/usr/local/bin:/usr/bin:/bin' "$TMPDIR_NEW/roadie-systemd"; then
  echo "FAIL: Roadie systemd PATH does not include managed Homeboy and Roadie directories"
  exit 1
fi
for required in ROADIE_MANAGED=1 ROADIE_NO_DEFAULT_CHANNEL=1 \
  ROADIE_SERVICE_TOKEN_FILE=/etc/wp-coding-agents/roadie/send-token; do
  grep -Fq "Environment=$required" "$TMPDIR_NEW/roadie-systemd" \
    || { echo "FAIL: Roadie systemd unit is missing Environment=$required"; exit 1; }
done
# Pi is Roadie's only backend (roadie#177): ROADIE_BACKEND is never rendered.
if grep -q '^Environment=ROADIE_BACKEND=' "$TMPDIR_NEW/roadie-systemd"; then
  echo "FAIL: Roadie systemd unit renders the removed ROADIE_BACKEND selector"
  exit 1
fi
if grep -q '^Environment=ROADIE_BOT_TOKEN=' "$TMPDIR_NEW/roadie-systemd"; then
  echo "FAIL: Roadie systemd unit inlines the bot token instead of a file reference"
  exit 1
fi
# The fixture config root has no channels.yaml, so the baseline render must
# not bind one — host-managed /opt/roadie-config/channels.yaml must not leak.
if grep -q 'ROADIE_CHANNELS_CONFIG' "$TMPDIR_NEW/roadie-systemd"; then
  echo "FAIL: Roadie systemd unit leaked ROADIE_CHANNELS_CONFIG from ambient host state"
  exit 1
fi

# launchd ---------------------------------------------------------------
PLATFORM="mac"
LOCAL_MODE=true
HOME_SAVE="$HOME"
export HOME="$SERVICE_HOME"
ROADIE_BIN="/opt/homebrew/bin/roadie"

render_with_bridge roadie render_launchd com.wp.roadie | strip_fixture_root > "$TMPDIR_NEW/roadie-launchd"
if grep -q 'ROADIE_CHANNELS_CONFIG' "$TMPDIR_NEW/roadie-launchd"; then
  echo "FAIL: Roadie launchd plist leaked ROADIE_CHANNELS_CONFIG from ambient host state"
  exit 1
fi

export HOME="$HOME_SAVE"

# Check the full attribution contract independently of snapshot update mode.
python3 - "$TMPDIR_NEW" <<'PY'
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
unit = (root / "roadie-systemd").read_text()
line = next(line for line in unit.splitlines() if line.startswith("Environment=ROADIE_SHELL_ENV="))
systemd_env = json.loads(line.split("=", 2)[2][1:-1].replace('\\"', '"'))
plist = ET.parse(root / "roadie-launchd").getroot()
env = plist.find("./dict/dict")
children = list(env)
launchd_env = json.loads(next(children[i + 1].text for i, child in enumerate(children) if child.text == "ROADIE_SHELL_ENV"))
for actual, binary in (
    (systemd_env, "/usr/local/lib/wp-coding-agents/roadie/bin/roadie"),
    (launchd_env, "/opt/homebrew/bin/roadie"),
):
    assert actual == {
        "HOMEBOY_CALLER_CONTEXT": "roadie:session:{session_id}",
        "HOMEBOY_REQUESTER": "{person_id}",
        "HOMEBOY_SESSION_THREAD_ID": "{thread_id}",
        "HOMEBOY_SESSION_SEND_COMMAND": f"{binary} send",
    }, actual
PY

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

# A real command lookup must pick managed Homeboy ahead of the legacy service
# home bin that also contains a `homeboy` executable.
mkdir -p "$TMPDIR_NEW/managed" "$TMPDIR_NEW/legacy"
PLATFORM="linux"
LOCAL_MODE=false
SERVICE_USER="chubes"
export PLATFORM LOCAL_MODE SERVICE_USER
printf '#!/bin/sh\nexit 0\n' > "$TMPDIR_NEW/managed/homeboy"
printf '#!/bin/sh\nexit 0\n' > "$TMPDIR_NEW/legacy/homeboy"
chmod 0755 "$TMPDIR_NEW/managed/homeboy" "$TMPDIR_NEW/legacy/homeboy"
export WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMPDIR_NEW/managed/homeboy"
ROADIE_BIN="$TMPDIR_NEW/legacy/roadie"
ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
ROADIE_ENV="$(roadie_env_block)"
ROADIE_RENDERED="$(render_with_bridge roadie render_systemd roadie.service "$ROADIE_ENV")"
RENDERED_PATH="$(printf '%s\n' "$ROADIE_RENDERED" | sed -n 's/^Environment=PATH=//p' | sed -n '1p')"
RESOLVED_HOMEBOY="$(env PATH="$RENDERED_PATH" /bin/sh -c 'command -v homeboy')"
if [ "$RESOLVED_HOMEBOY" != "$TMPDIR_NEW/managed/homeboy" ]; then
  echo "FAIL: Roadie systemd PATH '$RENDERED_PATH' resolves $RESOLVED_HOMEBOY instead of managed Homeboy"
  exit 1
fi
echo "  ok   Roadie PATH resolves the managed binary ahead of the legacy home bin"
UPGRADE_ENV="$(_ensure_systemd_path_first "Environment=PATH=$TMPDIR_NEW/legacy:$TMPDIR_NEW/managed:/usr/bin:$TMPDIR_NEW/legacy" "$TMPDIR_NEW/managed")"
UPGRADE_PATH="$(printf '%s\n' "$UPGRADE_ENV" | sed -n 's/^Environment=PATH=//p' | sed -n '1p')"
RESOLVED_HOMEBOY="$(env PATH="$UPGRADE_PATH" /bin/sh -c 'command -v homeboy')"
if [ "$RESOLVED_HOMEBOY" != "$TMPDIR_NEW/managed/homeboy" ] || [ "${UPGRADE_PATH%%:*}" != "$TMPDIR_NEW/managed" ]; then
  echo "FAIL: upgraded Roadie PATH '$UPGRADE_PATH' resolves $RESOLVED_HOMEBOY instead of managed Homeboy"
  exit 1
fi
echo "  ok   upgrade moves managed Homeboy ahead of legacy PATH entries"
unset WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN

# Reload, rather than kickstart, is required when the managed plist changes.
# Exercise the rendered shell command with a HOME containing spaces.
HOME_SAVE="$HOME"
export HOME="$TMPDIR_NEW/home with spaces"
RESTART_COMMAND="$(render_with_bridge roadie restart_cmd local-launchd)"
export HOME="$HOME_SAVE"
CALLS_FILE="$TMPDIR_NEW/launchctl-calls"
export CALLS_FILE
launchctl() { printf '%s\n' "$*" >> "$CALLS_FILE"; }
export -f launchctl
bash -c "$RESTART_COMMAND"
python3 - "$CALLS_FILE" "$TMPDIR_NEW/home with spaces/Library/LaunchAgents/com.wp.roadie.plist" "gui/$(id -u)" <<'PY'
import pathlib,sys
calls=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert calls==[f'bootout {sys.argv[3]} {sys.argv[2]}',f'bootstrap {sys.argv[3]} {sys.argv[2]}'],calls
PY
echo "  ok   managed launchd restart reloads the plist with correctly quoted paths"

# ---------------------------------------------------------------------------
# Channels policy fixture (#776): when the config root the TEST owns carries
# channels.yaml, both renders must bind ROADIE_CHANNELS_CONFIG to it. This is
# the positive half of the hermetic contract above: the binding comes from
# the fixture, so the case passes identically on a host with or without a
# real /opt/roadie-config/channels.yaml.
# ---------------------------------------------------------------------------
PLATFORM="linux"
LOCAL_MODE=false
export PLATFORM LOCAL_MODE
ROADIE_BIN="$ROADIE_SYSTEM_PREFIX/bin/roadie"
ROADIE_DATA_DIR="$FIXTURE_HOST_ROOT$SERVICE_HOME/.roadie"
printf 'channels: {}\n' > "$ROADIE_CONFIG_DIR/channels.yaml"
CHANNELS_SYSTEMD="$(render_with_bridge roadie render_systemd roadie.service "$(roadie_env_block)" | strip_fixture_root)"
if ! printf '%s\n' "$CHANNELS_SYSTEMD" | grep -Fq 'Environment=ROADIE_CHANNELS_CONFIG="/opt/roadie-config/channels.yaml"'; then
  echo "FAIL: systemd render does not bind ROADIE_CHANNELS_CONFIG to the fixture channels.yaml"
  exit 1
fi
echo "  ok   systemd render binds ROADIE_CHANNELS_CONFIG when the fixture provides channels.yaml"

PLATFORM="mac"
LOCAL_MODE=true
HOME_SAVE="$HOME"
export HOME="$SERVICE_HOME"
ROADIE_BIN="/opt/homebrew/bin/roadie"
mkdir -p "$ROADIE_DATA_DIR/roadie-config"
printf 'channels: {}\n' > "$ROADIE_DATA_DIR/roadie-config/channels.yaml"
CHANNELS_LAUNCHD="$(render_with_bridge roadie render_launchd com.wp.roadie | strip_fixture_root)"
export HOME="$HOME_SAVE"
if ! printf '%s\n' "$CHANNELS_LAUNCHD" | grep -Fq '<key>ROADIE_CHANNELS_CONFIG</key>' \
   || ! printf '%s\n' "$CHANNELS_LAUNCHD" | grep -Fq '<string>/home/chubes/.roadie/roadie-config/channels.yaml</string>'; then
  echo "FAIL: launchd render does not bind ROADIE_CHANNELS_CONFIG to the fixture channels.yaml"
  exit 1
fi
echo "  ok   launchd render binds ROADIE_CHANNELS_CONFIG when the fixture provides channels.yaml"
rm -f "$ROADIE_CONFIG_DIR/channels.yaml" "$ROADIE_DATA_DIR/roadie-config/channels.yaml"
