#!/bin/bash
# tests/roadie-managed-env.sh — Roadie's managed env reaches every render site.
#
# A managed Roadie service must carry ROADIE_MANAGED=1 (no self-upgrade),
# ROADIE_NO_DEFAULT_CHANNEL=1 (no general-purpose channel or tutorial thread
# on start), ROADIE_PROMPT_CONFIG and ROADIE_SERVICE_TOKEN_FILE. The fresh
# systemd unit, the upgrade-time merge into an existing unit, and the launchd
# plist must all carry them; an upgrade that adds them only to fresh installs
# leaves every existing host on defaults forever.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"
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

echo "==> upgrade merges managed env into an already-installed unit"

SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site"

# A Roadie unit without the managed keys, plus an operator-owned variable
# that must survive the merge.
cat > "$SYSTEMD_UNIT_DIR/roadie.service" <<EOF
[Service]
User=root
WorkingDirectory=$TMP/site
Environment=HOME=/root
Environment=PATH=/usr/bin:/bin
Environment=ROADIE_DATA_DIR=/root/.roadie
Environment=DATAMACHINE_SITE_PATH=$TMP/site
Environment=DATAMACHINE_WP_CMD=wp
Environment=HOST_CUSTOM=preserved
ExecStart=/usr/bin/roadie --data-dir /root/.roadie --auto-restart
EOF

unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT AGENT_SLUG
initialize_roadie_overrides
ROADIE_UNIT=roadie.service
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
ROADIE_SYSTEM_PREFIX="$TMP/roadie-prefix"
ROADIE_SECRETS_ROOT="$TMP/secrets"
PATH=/usr/bin:/bin
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
WP_CMD=wp
WP_CLI_TRANSPORT=(wp)
IS_STUDIO=false
systemctl() { :; }

bridge_update_systemd

if grep -Fq 'Environment=DATAMACHINE_WP_TRANSPORT_JSON="[\"wp\"]"' "$SYSTEMD_UNIT_DIR/roadie.service"; then
  check 0 "upgrade writes the argv-native WordPress transport"
else
  check 1 "upgrade writes the argv-native WordPress transport"
fi
if grep -q '^Environment=DATAMACHINE_WP_CMD=' "$SYSTEMD_UNIT_DIR/roadie.service"; then
  check 1 "upgrade removes the legacy WordPress command"
else
  check 0 "upgrade removes the legacy WordPress command"
fi

UNIT="$SYSTEMD_UNIT_DIR/roadie.service"
MANAGED_KEYS="ROADIE_MANAGED=1 ROADIE_NO_DEFAULT_CHANNEL=1 ROADIE_PROMPT_CONFIG=/opt/roadie-config/prompt-config.yaml ROADIE_SERVICE_TOKEN_FILE=$TMP/secrets/roadie/send-token"
check_managed_once() {
  local key
  for key in $MANAGED_KEYS; do
    if [ "$(grep -cFx "Environment=$key" "$UNIT")" -eq 1 ]; then
      check 0 "$1: $key exactly once"
    else
      check 1 "$1: $key exactly once"
    fi
  done
}
check_managed_once "upgrade adds"
if grep -q '^Environment=HOST_CUSTOM=preserved$' "$UNIT"; then
  check 0 "operator-owned env survives the merge"
else
  check 1 "operator-owned env survives the merge"
fi

# Re-running must not accumulate duplicates.
bridge_update_systemd
check_managed_once "re-run keeps"

echo "==> launchd plist carries the managed env"

PLIST="$(SITE_PATH="$TMP/site" LOCAL_MODE=true ROADIE_DATA_DIR="$TMP/.roadie" ROADIE_BIN=/usr/bin/roadie \
  bridge_render_launchd com.wp.roadie 2>/dev/null)"
for key in ROADIE_MANAGED ROADIE_NO_DEFAULT_CHANNEL; do
  if printf '%s' "$PLIST" | grep -A1 "<key>$key</key>" | grep -q '<string>1</string>'; then
    check 0 "launchd plist sets $key=1"
  else
    check 1 "launchd plist sets $key=1"
  fi
done
for key in ROADIE_PROMPT_CONFIG ROADIE_SERVICE_TOKEN_FILE; do
  if printf '%s' "$PLIST" | grep -q "<key>$key</key>"; then
    check 0 "launchd plist declares $key"
  else
    check 1 "launchd plist declares $key"
  fi
done
if printf '%s' "$PLIST" | grep -q '<key>DATAMACHINE_WP_TRANSPORT_JSON</key>'; then
  check 0 "launchd plist declares argv-native WordPress transport"
else
  check 1 "launchd plist declares argv-native WordPress transport"
fi
if printf '%s' "$PLIST" | grep -A1 '<key>DATAMACHINE_WP_TRANSPORT_JSON</key>' | grep -q '<string>\["wp"\]</string>'; then
  check 0 "launchd plist stores the canonical argv JSON"
else
  check 1 "launchd plist stores the canonical argv JSON"
fi

WP_CLI_TRANSPORT=("/tmp/wp cli" "--flag with spaces")
PLIST_SPACES="$(SITE_PATH="$TMP/site" LOCAL_MODE=true ROADIE_DATA_DIR="$TMP/.roadie" ROADIE_BIN=/usr/bin/roadie \
  bridge_render_launchd com.wp.roadie 2>/dev/null)"
if printf '%s' "$PLIST_SPACES" | grep -q '<string>\["/tmp/wp cli","--flag with spaces"\]</string>'; then
  check 0 "launchd plist preserves paths and args with spaces"
else
  check 1 "launchd plist preserves paths and args with spaces"
fi
if [ "$(_roadie_datamachine_wp_transport_systemd_env)" = 'Environment=DATAMACHINE_WP_TRANSPORT_JSON="[\"/tmp/wp cli\",\"--flag with spaces\"]"' ]; then
  check 0 "systemd env quotes argv JSON when paths or args contain spaces"
else
  check 1 "systemd env quotes argv JSON when paths or args contain spaces"
fi
WP_CLI_TRANSPORT=(wp)
if [ "$(_roadie_datamachine_wp_transport_systemd_env)" = 'Environment=DATAMACHINE_WP_TRANSPORT_JSON="[\"wp\"]"' ]; then
  check 0 "systemd env quotes compact argv JSON so systemd keeps the quotes"
else
  check 1 "systemd env quotes compact argv JSON so systemd keeps the quotes"
fi

echo "==> the service user's OpenCode wins over a distro copy"

# Roadie spawns `opencode` from PATH. A stale /usr/bin/opencode must not
# shadow the one the OpenCode installer puts in ~/.opencode/bin.
FAKE_HOME="$TMP/home-opencode"
mkdir -p "$FAKE_HOME/.opencode/bin"
printf '#!/bin/sh\n' > "$FAKE_HOME/.opencode/bin/opencode"
chmod +x "$FAKE_HOME/.opencode/bin/opencode"
# First PATH dir that could supply `opencode`: the user's, or a system dir.
first_opencode_dir() {
  printf '%s\n' "$1" | tr ':' '\n' \
    | grep -m1 -xE "$FAKE_HOME/\.opencode/bin|/usr/bin|/bin|/usr/local/bin" || true
}
FRESH_PATH="$(SERVICE_HOME="$FAKE_HOME" SERVICE_USER=opencode ROADIE_BIN=/usr/bin/roadie _roadie_path_value)"
[ "$(first_opencode_dir "$FRESH_PATH")" = "$FAKE_HOME/.opencode/bin" ]
check $? "fresh unit PATH puts ~/.opencode/bin before system dirs"

# An installed unit written without it gets it first on upgrade.
SAVED_HOME="$SERVICE_HOME"
SERVICE_HOME="$FAKE_HOME"
sed -i "s|^Environment=PATH=.*|Environment=PATH=/usr/local/bin:/usr/bin:/bin|" "$UNIT"
bridge_update_systemd >/dev/null 2>&1
UPGRADED_PATH="$(sed -n 's/^Environment=PATH=//p' "$UNIT")"
[ "${UPGRADED_PATH%%:*}" = "$FAKE_HOME/.opencode/bin" ]
check $? "upgrade moves ~/.opencode/bin to the front of an installed unit's PATH"
[ "$(grep -o "$FAKE_HOME/.opencode/bin" <<< "$UPGRADED_PATH" | wc -l)" -eq 1 ]
check $? "and only once"
SERVICE_HOME="$SAVED_HOME"

echo "==> fresh install and upgrade share one env source"

# The fresh unit and the upgrade merge both build from _roadie_template_env, so
# a managed key added there reaches both render sites.
for fn in _roadie_install_systemd bridge_update_systemd; do
  if sed -n "/^$fn()/,/^}/p" "$SCRIPT_DIR/bridges/roadie.sh" | grep -q '_roadie_template_env'; then
    check 0 "$fn builds from _roadie_template_env"
  else
    check 1 "$fn builds from _roadie_template_env"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo
echo "OK: Roadie managed env is present in every render site"
