#!/bin/bash
# tests/kimaki-no-default-channel.sh — KIMAKI_NO_DEFAULT_CHANNEL is managed env.
#
# Kimaki recreates a general-purpose #kimaki-<bot> channel, welcome message, and
# tutorial thread on every start. remorses/kimaki@7a9ab1e8 added
# KIMAKI_NO_DEFAULT_CHANNEL=1 to opt out (fixes remorses/kimaki#175).
#
# The variable has to be in THREE render sites and it is easy to add it to only
# one: the fresh systemd unit, the upgrade-time template that merges into an
# already-installed unit, and the launchd plist. Only the launchd plist is
# covered by tests/bridge-render.sh snapshots, because bridge_render_systemd
# takes its env block as an argument rather than building it. That gap is what
# this file closes — an install that only gets the variable on a fresh setup
# leaves every existing host noisy forever.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/kimaki.sh"

FAILED=0
check() {
  if [ "$1" -eq 0 ]; then
    echo "  ok   $2"
  else
    echo "  FAIL $2"
    FAILED=$((FAILED + 1))
  fi
}

echo "==> upgrade merges the opt-out into an already-installed unit"

SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site"

# A unit as it exists on a host installed before the opt-out shipped: no
# KIMAKI_NO_DEFAULT_CHANNEL, plus an operator-owned variable that must survive.
cat > "$SYSTEMD_UNIT_DIR/kimaki.service" <<EOF
[Service]
User=root
WorkingDirectory=$TMP/site
Environment=HOME=/root
Environment=PATH=/usr/bin:/bin
Environment=KIMAKI_DATA_DIR=/root/.kimaki
Environment=DATAMACHINE_SITE_PATH=$TMP/site
Environment=DATAMACHINE_WP_CMD=wp
Environment=HOST_CUSTOM=preserved
ExecStart=/usr/bin/kimaki --data-dir /root/.kimaki --auto-restart
EOF

unset KIMAKI_UNIT KIMAKI_DATA_DIR KIMAKI_LOCK_PORT AGENT_SLUG
initialize_kimaki_overrides
KIMAKI_UNIT=kimaki.service
SITE_PATH="$TMP/site"
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=true
LOCAL_MODE=false
KIMAKI_DATA_DIR=/root/.kimaki
KIMAKI_DATA_DIR_EXPLICIT=false
KIMAKI_LOCK_PORT=""
KIMAKI_LOCK_PORT_EXPLICIT=false
AGENT_SLUG=""
AGENT_SLUG_EXPLICIT=false
KIMAKI_CONFIG_DIR=/opt/kimaki-config
KIMAKI_BIN=/usr/bin/kimaki
KIMAKI_SYSTEM_PREFIX_BINS="$TMP/no-kimaki"
PATH=/usr/bin:/bin
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
WP_CMD=wp
WP_CLI_TRANSPORT=(wp)
IS_STUDIO=false
systemctl() { :; }

bridge_update_systemd

grep -q '^Environment=DATAMACHINE_WP_TRANSPORT_JSON=\[\\"wp\\"\]$' "$SYSTEMD_UNIT_DIR/kimaki.service"
check $? "upgrade writes the argv-native WordPress transport"
if grep -q '^Environment=DATAMACHINE_WP_CMD=' "$SYSTEMD_UNIT_DIR/kimaki.service"; then
  check 1 "upgrade removes the legacy WordPress command"
else
  check 0 "upgrade removes the legacy WordPress command"
fi

UNIT="$SYSTEMD_UNIT_DIR/kimaki.service"
[ "$(grep -c '^Environment=KIMAKI_NO_DEFAULT_CHANNEL=1$' "$UNIT")" -eq 1 ]
check $? "upgrade adds the opt-out exactly once"
grep -q '^Environment=HOST_CUSTOM=preserved$' "$UNIT"
check $? "operator-owned env survives the merge"

# Re-running must not accumulate duplicates.
bridge_update_systemd
[ "$(grep -c '^Environment=KIMAKI_NO_DEFAULT_CHANNEL=1$' "$UNIT")" -eq 1 ]
check $? "re-running upgrade does not duplicate the opt-out"

echo "==> launchd plist carries the opt-out"

_kimaki_ai_gateway_launchd_env_xml() { :; }
PLIST="$(SITE_PATH="$TMP/site" KIMAKI_DATA_DIR="$TMP/.kimaki" KIMAKI_BIN=/usr/bin/kimaki \
  bridge_render_launchd com.wp.kimaki 2>/dev/null)"
printf '%s' "$PLIST" | grep -q '<key>KIMAKI_NO_DEFAULT_CHANNEL</key>'
check $? "launchd plist declares the opt-out key"
printf '%s' "$PLIST" | grep -A1 '<key>KIMAKI_NO_DEFAULT_CHANNEL</key>' | grep -q '<string>1</string>'
check $? "launchd plist sets it to 1"

echo "==> fresh systemd install declares the opt-out"

# _kimaki_install_systemd builds its env block inline and has heavy side
# effects, so assert against the source of the block rather than executing it.
# Both systemd env blocks must carry the key; a render site that forgets it is
# the exact regression this guards.
[ "$(grep -c '^Environment=KIMAKI_NO_DEFAULT_CHANNEL=1"\?$' "$SCRIPT_DIR/bridges/kimaki.sh")" -eq 2 ]
check $? "both systemd env blocks (fresh install + upgrade template) set it"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo
echo "OK: KIMAKI_NO_DEFAULT_CHANNEL is managed in every render site"
