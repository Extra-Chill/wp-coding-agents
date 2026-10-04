#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/roadie.sh"

# Top-level defaults must distinguish an absent ROADIE_UNIT from an explicitly
# supplied default unit. That explicit default prevents site-path auto-selection.
unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT AGENT_SLUG
initialize_roadie_overrides
[ "$ROADIE_UNIT" = roadie.service ]
[ "$ROADIE_UNIT_EXPLICIT" = false ]

ROADIE_UNIT=roadie.service
ROADIE_DATA_DIR=/override/from-env
AGENT_SLUG=agent-from-env
initialize_roadie_overrides
[ "$ROADIE_UNIT_EXPLICIT" = true ]
[ "$ROADIE_DATA_DIR_EXPLICIT" = true ]
[ "$AGENT_SLUG_EXPLICIT" = true ]

grep -q '^initialize_roadie_overrides$' "$SCRIPT_DIR/setup.sh"
grep -q '^initialize_roadie_overrides$' "$SCRIPT_DIR/upgrade.sh"
grep -A2 -- '--root)' "$SCRIPT_DIR/setup.sh" | grep -q 'SERVICE_USER_FORCED=true'
grep -A2 -- '--non-root)' "$SCRIPT_DIR/setup.sh" | grep -q 'SERVICE_USER_FORCED=true'

SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site-a" "$TMP/site-b"
cat > "$SYSTEMD_UNIT_DIR/roadie.service" <<EOF
[Service]
User=root
WorkingDirectory=$TMP/site-a
Environment=HOME=/root
Environment=ROADIE_DATA_DIR=/root/.roadie
Environment=DATAMACHINE_AGENT_SLUG=site-a
Environment=ROADIE_LOCK_PORT=3210
ExecStart=/usr/bin/roadie --data-dir /root/.roadie --auto-restart
EOF
cat > "$SYSTEMD_UNIT_DIR/roadie-site-b.service" <<EOF
[Service]
User=opencode
WorkingDirectory=$TMP/site-b
Environment=HOME=/home/opencode
Environment=ROADIE_DATA_DIR=/home/opencode/.roadie-site-b
Environment=DATAMACHINE_AGENT_SLUG=site-b
Environment=ROADIE_LOCK_PORT=6543
ExecStart=/usr/bin/roadie --data-dir /home/opencode/.roadie-site-b --auto-restart
EOF

SITE_PATH="$TMP/site-b"
ROADIE_UNIT=roadie.service
ROADIE_UNIT_EXPLICIT=false
ROADIE_DATA_DIR=/root/.roadie
ROADIE_DATA_DIR_EXPLICIT=false
ROADIE_LOCK_PORT=""
ROADIE_LOCK_PORT_EXPLICIT=false
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=false
RUN_AS_ROOT=true
AGENT_SLUG=""
LOCAL_MODE=false

_roadie_resolve_instance
[ "$ROADIE_UNIT" = roadie-site-b.service ]
[ "$SERVICE_USER" = opencode ]
[ "$SERVICE_HOME" = /home/opencode ]
[ "$ROADIE_DATA_DIR" = /home/opencode/.roadie-site-b ]
[ "$ROADIE_LOCK_PORT" = 6543 ]
[ "$AGENT_SLUG" = site-b ]
[ "$(bridge_restart_cmd vps)" = "systemctl restart roadie-site-b.service" ]
[ "$(bridge_verify_cmd vps)" = "systemctl status roadie-site-b.service && curl -fsS http://127.0.0.1:6543/health" ]

# Presence of ROADIE_UNIT=roadie.service is an explicit selection, even though
# it equals the default. It must beat the site-b WorkingDirectory match.
ROADIE_UNIT=roadie.service
ROADIE_UNIT_EXPLICIT=true
ROADIE_DATA_DIR=/root/.roadie
ROADIE_DATA_DIR_EXPLICIT=false
ROADIE_LOCK_PORT=""
ROADIE_LOCK_PORT_EXPLICIT=false
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=false
RUN_AS_ROOT=true
AGENT_SLUG=""
AGENT_SLUG_EXPLICIT=false
_roadie_resolve_instance
[ "$ROADIE_UNIT" = roadie.service ]
[ "$ROADIE_DATA_DIR" = /root/.roadie ]

# A forced setup identity must not be replaced by the selected unit's User=.
ROADIE_UNIT=roadie-site-b.service
ROADIE_UNIT_EXPLICIT=true
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=true
RUN_AS_ROOT=true
ROADIE_DATA_DIR=/forced/data
ROADIE_DATA_DIR_EXPLICIT=true
AGENT_SLUG=forced-agent
AGENT_SLUG_EXPLICIT=true
_roadie_resolve_instance
[ "$SERVICE_USER" = root ]
[ "$SERVICE_HOME" = /root ]
[ "$RUN_AS_ROOT" = true ]

SERVICE_USER=opencode
SERVICE_HOME=/home/opencode
SERVICE_USER_FORCED=false
RUN_AS_ROOT=false
ROADIE_DATA_DIR=/home/opencode/.roadie-site-b
ROADIE_DATA_DIR_EXPLICIT=false
ROADIE_LOCK_PORT=6543
ROADIE_LOCK_PORT_EXPLICIT=false
AGENT_SLUG=site-b
AGENT_SLUG_EXPLICIT=false

ROADIE_SYSTEM_PREFIX="$TMP/roadie-prefix"
ROADIE_SECRETS_ROOT="$TMP/secrets"
PATH=/usr/bin:/bin
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
WP_CMD=wp
IS_STUDIO=false
systemctl() { :; }
_roadie_provision_package() { :; }

other_before=$(cksum "$SYSTEMD_UNIT_DIR/roadie.service")
bridge_update_systemd
other_after=$(cksum "$SYSTEMD_UNIT_DIR/roadie.service")
[ "$other_before" = "$other_after" ]
grep -q '^WorkingDirectory=.*/site-b$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service"
grep -q '^Environment=ROADIE_LOCK_PORT=6543$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service"
grep -q '^Environment=DATAMACHINE_AGENT_SLUG=site-b$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service"

# Explicit managed overrides replace, rather than merge-preserve, installed
# values. Unmanaged Environment= values remain owned by the host.
printf '%s\n' 'Environment=HOST_CUSTOM=preserved' >> "$SYSTEMD_UNIT_DIR/roadie-site-b.service"
ROADIE_DATA_DIR=/explicit/data
ROADIE_DATA_DIR_EXPLICIT=true
ROADIE_LOCK_PORT=7654
ROADIE_LOCK_PORT_EXPLICIT=true
AGENT_SLUG=explicit-agent
AGENT_SLUG_EXPLICIT=true
SERVICE_USER_FORCED=true
bridge_update_systemd
[ "$(grep -c '^Environment=ROADIE_DATA_DIR=/explicit/data$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service")" -eq 1 ]
[ "$(grep -c '^Environment=ROADIE_LOCK_PORT=7654$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service")" -eq 1 ]
[ "$(grep -c '^Environment=DATAMACHINE_AGENT_SLUG=explicit-agent$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service")" -eq 1 ]
if grep -q '^Environment=ROADIE_DATA_DIR=/home/opencode/.roadie-site-b$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service"; then
  echo "FAIL: old data-directory environment was preserved" >&2
  exit 1
fi
if grep -q '^Environment=DATAMACHINE_AGENT_SLUG=site-b$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service"; then
  echo "FAIL: old agent-slug environment was preserved" >&2
  exit 1
fi
grep -q '^Environment=HOST_CUSTOM=preserved$' "$SYSTEMD_UNIT_DIR/roadie-site-b.service"

# Restore the selected instance values used by the remaining rendering checks.
ROADIE_DATA_DIR=/home/opencode/.roadie-site-b
ROADIE_LOCK_PORT=6543
AGENT_SLUG=site-b

[ "$(_roadie_instance_suffix)" = -site-b ]
cli_channel_register() { printf '%s\n%s\n' "$2" "$5"; }
# Each instance has its own send token and reaches its own bot (lock port).
channel_registration=$(LOCAL_MODE=false ROADIE_DATA_DIR=/home/opencode/.roadie-site-b _roadie_register_cli_channel)
echo "$channel_registration" | grep -qx "$TMP/roadie-prefix/bin/roadie"
echo "$channel_registration" | grep -qF "\"ROADIE_SERVICE_TOKEN_FILE\":\"$TMP/secrets/roadie-site-b/send-token\""
echo "$channel_registration" | grep -qF '"ROADIE_DATA_DIR":"/home/opencode/.roadie-site-b"'
echo "$channel_registration" | grep -qF '"ROADIE_LOCK_PORT":"6543"'

rendered=$(bridge_render_systemd roadie-site-b.service 'Environment=HOME=/home/opencode')
echo "$rendered" | grep -q '^Environment=ROADIE_LOCK_PORT=6543$'
if echo "$rendered" | grep -q -- '--lock-port'; then
  echo "FAIL: renderer emitted obsolete lock-port argument" >&2
  exit 1
fi
if echo "$rendered" | grep -q 'pkill'; then
  echo "FAIL: rendered unit kills processes host-user-wide; Roadie cleans up its own orphans" >&2
  exit 1
fi

cp "$SYSTEMD_UNIT_DIR/roadie-site-b.service" "$TMP/site-b.unit"
sed "s|^WorkingDirectory=.*|WorkingDirectory=$TMP/site-a|" "$TMP/site-b.unit" > "$SYSTEMD_UNIT_DIR/roadie-site-b.service"
if (SITE_PATH="$TMP/site-a" ROADIE_UNIT=roadie.service ROADIE_UNIT_EXPLICIT=false ROADIE_DATA_DIR_EXPLICIT=false _roadie_resolve_instance) >/dev/null 2>&1; then
  echo "FAIL: ambiguous site path did not fail" >&2
  exit 1
fi

if (ROADIE_LOCK_PORT=not-a-port _roadie_validate_lock_port) >/dev/null 2>&1; then
  echo "FAIL: invalid lock port did not fail" >&2
  exit 1
fi

for invalid_unit in '../roadie.service' '/tmp/roadie.service' 'roadie-../../escape.service' 'roadie bad.service' 'roadie-.service'; do
  if (_roadie_normalize_unit_name "$invalid_unit") >/dev/null 2>&1; then
    echo "FAIL: unsafe unit name was accepted: $invalid_unit" >&2
    exit 1
  fi
done

echo "PASS: tests/roadie-multi-instance.sh"
