#!/bin/bash
# tests/roadie-speaker-context-gate.sh — --speaker-context only drops managed
# memory when the service really runs wordpress-context.mjs (#729).
#
# The Roadie context provider is the wordpress-context Roadie plugin, carried
# in ROADIE_PLUGINS. If a unit pre-dates the managed plugin merge and still
# runs without it, removing the memory mapping from opencode.json leaves
# sessions with no SOUL/MEMORY/SITE/RULES/USER at all — the failure seen on
# chubes.net. The gate must hold the managed memory in place until the unit's
# plugin list contains the plugin, and stay enabled for fresh installs where
# no service file exists yet.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"
source "$SCRIPT_DIR/lib/homeboy.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/roadie.sh"

FAILED=0
check() {
  if [ "$1" -eq 0 ]; then
    echo "  ok   $2"
  else
    echo "  FAIL $2"
    FAILED=$((FAILED + 1))
  fi
}

unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT AGENT_SLUG ROADIE_CONFIG_DIR
initialize_roadie_overrides
ROADIE_UNIT=roadie.service
ROADIE_CONFIG_DIR="$TMP/roadie-config"
SITE_PATH="$TMP/site"
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=true
LOCAL_MODE=false
ROADIE_DATA_DIR=/root/.roadie
ROADIE_DATA_DIR_EXPLICIT=false
ROADIE_LOCK_PORT=""
ROADIE_LOCK_PORT_EXPLICIT=false
AGENT_SLUG=""
AGENT_SLUG_EXPLICIT=false
CHAT_BRIDGE=roadie
SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$SITE_PATH"
export HOME="$TMP/home"
mkdir -p "$HOME"

PLUGIN_DIR="/opt/roadie-config/roadie-plugins"
CONTEXT_JSON="$(roadie_config_dir)/wordpress-context.json"

gate_on_unit() {
  printf '%s\n' "$1" > "$SYSTEMD_UNIT_DIR/roadie.service"
  if roadie_speaker_context_enabled; then
    return 0
  fi
  return 1
}

echo "==> no service file yet (fresh install) stays enabled"

[ -f "$CONTEXT_JSON" ] && rm -f "$CONTEXT_JSON"
mkdir -p "$(dirname "$CONTEXT_JSON")"
printf '{}\n' > "$CONTEXT_JSON"
if roadie_speaker_context_enabled; then
  check 0 "context file + no unit: speaker context enabled"
else
  check 1 "context file + no unit: speaker context enabled"
fi

echo "==> a unit without the plugin holds the gate closed"

if gate_on_unit "[Service]
User=root
Environment=ROADIE_PLUGINS=$PLUGIN_DIR/host-upgrade.mjs
Environment=ROADIE_SHELL_ENV=\"{}\"
ExecStart=/usr/bin/roadie --auto-restart"; then
  check 1 "stale unit without wordpress-context.mjs: gate closed"
else
  check 0 "stale unit without wordpress-context.mjs: gate closed"
fi

echo "==> a unit carrying the plugin opens the gate"

if gate_on_unit "[Service]
User=root
Environment=ROADIE_PLUGINS=$PLUGIN_DIR/host-upgrade.mjs,$PLUGIN_DIR/wordpress-context.mjs,$PLUGIN_DIR/fork-workspace.mjs
Environment=ROADIE_SHELL_ENV=\"{}\"
ExecStart=/usr/bin/roadie --auto-restart"; then
  check 0 "unit with wordpress-context.mjs: gate open"
else
  check 1 "unit with wordpress-context.mjs: gate open"
fi

echo "==> a unit with no plugin line at all holds the gate closed"

if gate_on_unit "[Service]
User=root
Environment=ROADIE_SHELL_ENV=\"{}\"
ExecStart=/usr/bin/roadie --auto-restart"; then
  check 1 "unit without a ROADIE_PLUGINS line: gate closed"
else
  check 0 "unit without a ROADIE_PLUGINS line: gate closed"
fi

echo "==> no context file keeps the gate closed regardless"

rm -f "$CONTEXT_JSON"
gate_on_unit "[Service]
User=root
Environment=ROADIE_PLUGINS=$PLUGIN_DIR/wordpress-context.mjs
Environment=ROADIE_SHELL_ENV=\"{}\"
ExecStart=/usr/bin/roadie --auto-restart" || true
if roadie_speaker_context_enabled; then
  check 1 "no wordpress-context.json: gate closed even with the plugin"
else
  check 0 "no wordpress-context.json: gate closed even with the plugin"
fi

echo "==> the launchd fallback reads com.wp.roadie.plist"

rm -f "$SYSTEMD_UNIT_DIR/roadie.service"
printf '{}\n' > "$CONTEXT_JSON"
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"
PLIST="$PLIST_DIR/com.wp.roadie.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ROADIE_PLUGINS</key>
<string>$PLUGIN_DIR/host-upgrade.mjs</string>
</dict></plist>
PLIST
if roadie_speaker_context_enabled; then
  check 1 "launchd plist without the plugin: gate closed"
else
  check 0 "launchd plist without the plugin: gate closed"
fi
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ROADIE_PLUGINS</key>
<string>$PLUGIN_DIR/wordpress-context.mjs</string>
</dict></plist>
PLIST
if roadie_speaker_context_enabled; then
  check 0 "launchd plist with the plugin: gate open"
else
  check 1 "launchd plist with the plugin: gate open"
fi

if [ "$FAILED" -gt 0 ]; then
  echo "roadie-speaker-context-gate: $FAILED failure(s)"
  exit 1
fi
echo "roadie-speaker-context-gate: all assertions passed"
