#!/bin/bash
# tests/codebox-database-env-wiring.sh — the codebox test database credentials
# have to actually reach the kimaki service (#624), the same way the WP AI
# Gateway token does: an EnvironmentFile=- line on the systemd unit.
#
# Mirrors tests/kimaki-no-default-channel.sh's split: the fresh-install
# systemd render (_kimaki_install_systemd) builds its env block inline with
# heavy side effects, so that half is asserted against source text. The
# upgrade-time template (bridge_update_systemd) merges into an existing unit
# file with no other side effects, so that half is exercised directly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"
source "$SCRIPT_DIR/lib/systems-capabilities.sh"
source "$SCRIPT_DIR/lib/codebox-database.sh"
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

echo "==> fresh systemd install declares the opt-in EnvironmentFile line"

# _kimaki_install_systemd builds its env block inline and has heavy side
# effects (copies bridges/kimaki into /opt/kimaki-config, enables the unit),
# so assert against the source of the block rather than executing it — the
# same approach tests/kimaki-no-default-channel.sh uses for this function.
if grep -qF 'EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE' "$SCRIPT_DIR/bridges/kimaki.sh"; then
  check 0 "the fresh-install and upgrade env blocks reference the codebox db env file"
else
  check 1 "the fresh-install and upgrade env blocks reference the codebox db env file"
fi
if [ "$(grep -cF 'EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE' "$SCRIPT_DIR/bridges/kimaki.sh")" -eq 2 ]; then
  check 0 "both systemd env blocks (fresh install + upgrade template) carry it"
else
  check 1 "both systemd env blocks (fresh install + upgrade template) carry it"
fi
if grep -B1 -F 'EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE' "$SCRIPT_DIR/bridges/kimaki.sh" | grep -q 'codebox_database_enabled'; then
  check 0 "the line is gated on codebox_database_enabled, not unconditional"
else
  check 1 "the line is gated on codebox_database_enabled, not unconditional"
fi

echo ""
echo "==> upgrade merges the EnvironmentFile line into an already-installed unit"

SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site"

cat > "$SYSTEMD_UNIT_DIR/kimaki.service" <<EOF
[Service]
User=root
WorkingDirectory=$TMP/site
Environment=HOME=/root
Environment=PATH=/usr/bin:/bin
Environment=KIMAKI_DATA_DIR=/root/.kimaki
Environment=DATAMACHINE_SITE_PATH=$TMP/site
Environment=DATAMACHINE_WP_CMD=wp
ExecStart=/usr/bin/kimaki --data-dir /root/.kimaki --auto-restart
EOF

# SERVICE_USER=root (matching tests/kimaki-no-default-channel.sh) deliberately
# avoids _kimaki_uses_service_owned_prefix — that path shells out to provision
# a service-owned npm package and needs either root+sudo or literally running
# as the service user, neither of which a CI runner satisfies. Irrelevant to
# what this file asserts (the EnvironmentFile= line), so it is sidestepped
# rather than mocked.
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

UNIT="$SYSTEMD_UNIT_DIR/kimaki.service"

echo "  -- managed-vps disabled: no line is added"
SYSTEMS_CAPABILITIES_PROFILE=""
CODEBOX_DATABASE_ENV_FILE="/etc/wp-coding-agents/codebox-db.env"
bridge_update_systemd
if grep -qF "EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE" "$UNIT"; then
  check 1 "no EnvironmentFile line when the managed-vps profile is not enabled"
else
  check 0 "no EnvironmentFile line when the managed-vps profile is not enabled"
fi

echo "  -- managed-vps enabled: the line is added"
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
bridge_update_systemd
if [ "$(grep -cF "EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE" "$UNIT")" -eq 1 ]; then
  check 0 "the EnvironmentFile line is added exactly once"
else
  check 1 "the EnvironmentFile line is added exactly once"
fi

echo "  -- re-running upgrade does not duplicate the line"
bridge_update_systemd
if [ "$(grep -cF "EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE" "$UNIT")" -eq 1 ]; then
  check 0 "re-running upgrade does not duplicate the EnvironmentFile line"
else
  check 1 "re-running upgrade does not duplicate the EnvironmentFile line"
fi

echo "  -- an operator-set custom env file path is honored"
SYSTEMD_UNIT_DIR2="$TMP/systemd2"
mkdir -p "$SYSTEMD_UNIT_DIR2"
cp "$UNIT" "$SYSTEMD_UNIT_DIR2/kimaki.service"
# Strip the previously-rendered line so the custom path is proven fresh.
grep -v "EnvironmentFile=-" "$SYSTEMD_UNIT_DIR2/kimaki.service" > "$SYSTEMD_UNIT_DIR2/kimaki.service.tmp"
mv "$SYSTEMD_UNIT_DIR2/kimaki.service.tmp" "$SYSTEMD_UNIT_DIR2/kimaki.service"
SYSTEMD_UNIT_DIR="$SYSTEMD_UNIT_DIR2"
CODEBOX_DATABASE_ENV_FILE="/opt/custom/codebox-db.env"
bridge_update_systemd
if grep -qF "EnvironmentFile=-/opt/custom/codebox-db.env" "$SYSTEMD_UNIT_DIR2/kimaki.service"; then
  check 0 "an operator-overridden CODEBOX_DATABASE_ENV_FILE path is honored"
else
  check 1 "an operator-overridden CODEBOX_DATABASE_ENV_FILE path is honored"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "codebox-database-env-wiring: all assertions passed"
else
  echo "codebox-database-env-wiring: $FAILED assertion(s) failed"
  exit 1
fi
