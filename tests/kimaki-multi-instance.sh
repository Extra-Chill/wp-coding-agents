#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/kimaki.sh"

# Top-level defaults must distinguish an absent KIMAKI_UNIT from an explicitly
# supplied default unit. That explicit default prevents site-path auto-selection.
unset KIMAKI_UNIT KIMAKI_DATA_DIR KIMAKI_LOCK_PORT AGENT_SLUG
initialize_kimaki_overrides
[ "$KIMAKI_UNIT" = kimaki.service ]
[ "$KIMAKI_UNIT_EXPLICIT" = false ]

KIMAKI_UNIT=kimaki.service
KIMAKI_DATA_DIR=/override/from-env
AGENT_SLUG=agent-from-env
initialize_kimaki_overrides
[ "$KIMAKI_UNIT_EXPLICIT" = true ]
[ "$KIMAKI_DATA_DIR_EXPLICIT" = true ]
[ "$AGENT_SLUG_EXPLICIT" = true ]

grep -q '^initialize_kimaki_overrides$' "$SCRIPT_DIR/setup.sh"
grep -q '^initialize_kimaki_overrides$' "$SCRIPT_DIR/upgrade.sh"
grep -A2 -- '--root)' "$SCRIPT_DIR/setup.sh" | grep -q 'SERVICE_USER_FORCED=true'
grep -A2 -- '--non-root)' "$SCRIPT_DIR/setup.sh" | grep -q 'SERVICE_USER_FORCED=true'

SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site-a" "$TMP/site-b"
cat > "$SYSTEMD_UNIT_DIR/kimaki.service" <<EOF
[Service]
User=root
WorkingDirectory=$TMP/site-a
Environment=HOME=/root
Environment=KIMAKI_DATA_DIR=/root/.kimaki
Environment=DATAMACHINE_AGENT_SLUG=site-a
ExecStart=/usr/bin/kimaki --data-dir /root/.kimaki --lock-port 3210 --auto-restart
EOF
cat > "$SYSTEMD_UNIT_DIR/kimaki-site-b.service" <<EOF
[Service]
User=opencode
WorkingDirectory=$TMP/site-b
Environment=HOME=/home/opencode
Environment=KIMAKI_DATA_DIR=/home/opencode/.kimaki-site-b
Environment=DATAMACHINE_AGENT_SLUG=site-b
ExecStart=/usr/bin/kimaki --data-dir /home/opencode/.kimaki-site-b --lock-port 6543 --auto-restart
EOF

SITE_PATH="$TMP/site-b"
KIMAKI_UNIT=kimaki.service
KIMAKI_UNIT_EXPLICIT=false
KIMAKI_DATA_DIR=/root/.kimaki
KIMAKI_DATA_DIR_EXPLICIT=false
KIMAKI_LOCK_PORT=""
KIMAKI_LOCK_PORT_EXPLICIT=false
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=false
RUN_AS_ROOT=true
AGENT_SLUG=""
LOCAL_MODE=false

_kimaki_resolve_instance
[ "$KIMAKI_UNIT" = kimaki-site-b.service ]
[ "$SERVICE_USER" = opencode ]
[ "$SERVICE_HOME" = /home/opencode ]
[ "$KIMAKI_DATA_DIR" = /home/opencode/.kimaki-site-b ]
[ "$KIMAKI_LOCK_PORT" = 6543 ]
[ "$AGENT_SLUG" = site-b ]
[ "$(bridge_restart_cmd vps)" = "systemctl restart kimaki-site-b.service" ]
[ "$(bridge_verify_cmd vps)" = "systemctl status kimaki-site-b.service" ]

# Presence of KIMAKI_UNIT=kimaki.service is an explicit selection, even though
# it equals the default. It must beat the site-b WorkingDirectory match.
KIMAKI_UNIT=kimaki.service
KIMAKI_UNIT_EXPLICIT=true
KIMAKI_DATA_DIR=/root/.kimaki
KIMAKI_DATA_DIR_EXPLICIT=false
KIMAKI_LOCK_PORT=""
KIMAKI_LOCK_PORT_EXPLICIT=false
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=false
RUN_AS_ROOT=true
AGENT_SLUG=""
AGENT_SLUG_EXPLICIT=false
_kimaki_resolve_instance
[ "$KIMAKI_UNIT" = kimaki.service ]
[ "$KIMAKI_DATA_DIR" = /root/.kimaki ]

# A forced setup identity must not be replaced by the selected unit's User=.
KIMAKI_UNIT=kimaki-site-b.service
KIMAKI_UNIT_EXPLICIT=true
SERVICE_USER=root
SERVICE_HOME=/root
SERVICE_USER_FORCED=true
RUN_AS_ROOT=true
KIMAKI_DATA_DIR=/forced/data
KIMAKI_DATA_DIR_EXPLICIT=true
AGENT_SLUG=forced-agent
AGENT_SLUG_EXPLICIT=true
_kimaki_resolve_instance
[ "$SERVICE_USER" = root ]
[ "$SERVICE_HOME" = /root ]
[ "$RUN_AS_ROOT" = true ]

SERVICE_USER=opencode
SERVICE_HOME=/home/opencode
SERVICE_USER_FORCED=false
RUN_AS_ROOT=false
KIMAKI_DATA_DIR=/home/opencode/.kimaki-site-b
KIMAKI_DATA_DIR_EXPLICIT=false
KIMAKI_LOCK_PORT=6543
KIMAKI_LOCK_PORT_EXPLICIT=false
AGENT_SLUG=site-b
AGENT_SLUG_EXPLICIT=false

KIMAKI_CONFIG_DIR=/opt/kimaki-config
KIMAKI_BIN=/usr/bin/kimaki
KIMAKI_SYSTEM_PREFIX_BINS="$TMP/no-kimaki"
PATH=/usr/bin:/bin
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
WP_CMD=wp
IS_STUDIO=false
systemctl() { :; }

other_before=$(cksum "$SYSTEMD_UNIT_DIR/kimaki.service")
bridge_update_systemd
other_after=$(cksum "$SYSTEMD_UNIT_DIR/kimaki.service")
[ "$other_before" = "$other_after" ]
grep -q '^WorkingDirectory=.*/site-b$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"
grep -q '^Environment=KIMAKI_LOCK_PORT=6543$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"
if grep -q -- '--lock-port' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"; then
  echo "FAIL: obsolete lock-port argument survived managed unit migration" >&2
  exit 1
fi
grep -q '^Environment=DATAMACHINE_AGENT_SLUG=site-b$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"

# Explicit managed overrides replace, rather than merge-preserve, installed
# values. Unmanaged Environment= values remain owned by the host.
printf '%s\n' 'Environment=HOST_CUSTOM=preserved' >> "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"
KIMAKI_DATA_DIR=/explicit/data
KIMAKI_DATA_DIR_EXPLICIT=true
KIMAKI_LOCK_PORT=7654
KIMAKI_LOCK_PORT_EXPLICIT=true
AGENT_SLUG=explicit-agent
AGENT_SLUG_EXPLICIT=true
SERVICE_USER_FORCED=true
bridge_update_systemd
[ "$(grep -c '^Environment=KIMAKI_DATA_DIR=/explicit/data$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service")" -eq 1 ]
[ "$(grep -c '^Environment=KIMAKI_LOCK_PORT=7654$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service")" -eq 1 ]
[ "$(grep -c '^Environment=DATAMACHINE_AGENT_SLUG=explicit-agent$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service")" -eq 1 ]
if grep -q '^Environment=KIMAKI_DATA_DIR=/home/opencode/.kimaki-site-b$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"; then
  echo "FAIL: old data-directory environment was preserved" >&2
  exit 1
fi
if grep -q '^Environment=DATAMACHINE_AGENT_SLUG=site-b$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"; then
  echo "FAIL: old agent-slug environment was preserved" >&2
  exit 1
fi
grep -q '^Environment=HOST_CUSTOM=preserved$' "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"

# Restore the selected instance values used by the remaining rendering checks.
KIMAKI_DATA_DIR=/home/opencode/.kimaki-site-b
KIMAKI_LOCK_PORT=6543
AGENT_SLUG=site-b

[ "$(_kimaki_instance_suffix)" = -site-b ]
cli_channel_register() { printf '%s\n%s\n' "$2" "$6"; }
channel_registration=$(LOCAL_MODE=false SERVICE_USER=opencode SERVICE_HOME=/home/opencode KIMAKI_DATA_DIR=/home/opencode/.kimaki-site-b KIMAKI_BIN=/usr/bin/kimaki _kimaki_register_cli_channel)
echo "$channel_registration" | grep -q '^/usr/local/bin/wp-coding-agents-kimaki-site-b-dispatch$'
echo "$channel_registration" | grep -q '"HOME":"/home/opencode","KIMAKI_DATA_DIR":"/home/opencode/.kimaki-site-b"'

wrapper_output=$(LOCAL_MODE=false SERVICE_USER=opencode SERVICE_HOME=/home/opencode KIMAKI_DATA_DIR=/home/opencode/.kimaki-site-b KIMAKI_BIN=/usr/bin/kimaki DRY_RUN=true _kimaki_install_dispatch_helpers)
echo "$wrapper_output" | grep -q 'wp-coding-agents-kimaki-site-b-dispatch'

rendered=$(bridge_render_systemd kimaki-site-b.service 'Environment=HOME=/home/opencode')
echo "$rendered" | grep -q '^Environment=KIMAKI_LOCK_PORT=6543$'
if echo "$rendered" | grep -q -- '--lock-port'; then
  echo "FAIL: renderer emitted obsolete lock-port argument" >&2
  exit 1
fi
if echo "$rendered" | grep -q 'pkill -TERM'; then
  echo "FAIL: custom instance contains host-user-wide stale worker cleanup" >&2
  exit 1
fi

cp "$SYSTEMD_UNIT_DIR/kimaki-site-b.service" "$TMP/site-b.unit"
sed "s|^WorkingDirectory=.*|WorkingDirectory=$TMP/site-a|" "$TMP/site-b.unit" > "$SYSTEMD_UNIT_DIR/kimaki-site-b.service"
if (SITE_PATH="$TMP/site-a" KIMAKI_UNIT=kimaki.service KIMAKI_UNIT_EXPLICIT=false KIMAKI_DATA_DIR_EXPLICIT=false _kimaki_resolve_instance) >/dev/null 2>&1; then
  echo "FAIL: ambiguous site path did not fail" >&2
  exit 1
fi

if (KIMAKI_LOCK_PORT=not-a-port _kimaki_validate_lock_port) >/dev/null 2>&1; then
  echo "FAIL: invalid lock port did not fail" >&2
  exit 1
fi

for invalid_unit in '../kimaki.service' '/tmp/kimaki.service' 'kimaki-../../escape.service' 'kimaki bad.service' 'kimaki-.service'; do
  if (_kimaki_normalize_unit_name "$invalid_unit") >/dev/null 2>&1; then
    echo "FAIL: unsafe unit name was accepted: $invalid_unit" >&2
    exit 1
  fi
done

echo "PASS: tests/kimaki-multi-instance.sh"
