#!/bin/bash
# tests/homeboy-daemon-pool-client.sh — the Homeboy daemon gets a durable
# Roadie pool client for local Pi Cooks (#870): a fixed pool proxy port on
# roadie.service, a registered client whose key and Pi agent dir live in a
# 0600 EnvironmentFile the daemon unit loads, idempotent re-runs that never
# rotate a stored key, and a verify check for an unauthenticated route.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/services/homeboy-daemon.sh"

log() { printf 'LOG: %s\n' "$*" >> "$TMP/warn.log"; }
warn() { printf 'WARN: %s\n' "$*" >> "$TMP/warn.log"; }
error() { printf 'ERROR: %s\n' "$*" >> "$TMP/warn.log"; return 1; }
systemctl() { :; }

SYSTEMD_UNIT_DIR="$TMP/systemd"
HOMEBOY_DAEMON_SYSTEMD_DIR="$TMP/systemd"
HOMEBOY_DAEMON_PI_ENV_FILE="$TMP/etc/homeboy/pi.env"
ENV_FILE="$HOMEBOY_DAEMON_PI_ENV_FILE"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site" "$TMP/home"

unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT AGENT_SLUG ROADIE_POOL_URL ROADIE_POOL_KEY ROADIE_POOL_PROXY_PORT HOMEBOY_DATA_DIR
initialize_roadie_overrides
ROADIE_UNIT=roadie.service
SITE_PATH="$TMP/site"
SERVICE_USER="$(id -un)"
SERVICE_HOME="$TMP/home"
SERVICE_USER_FORCED=true
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
ROADIE_DATA_DIR="$TMP/home/.roadie"
ROADIE_SYSTEM_PREFIX="$TMP/roadie-prefix"
ROADIE_SECRETS_ROOT="$TMP/secrets"
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
PENDING_ITEMS=()
WP_CMD=wp
WP_CLI_TRANSPORT=(wp)
IS_STUDIO=false
WP_CODING_AGENTS_TEST_EUID=0
ROADIE_PI_VERIFIED=none
_roadie_select_pi() { ROADIE_PI_BIN=/fixture/pi; }

# Managed Homeboy binary, so the daemon unit applies.
WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMP/prefix/wp-coding-agents/bin/homeboy"
mkdir -p "$(dirname "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN")"
printf '#!/bin/sh\n' > "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN"
chmod +x "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN"

# --- Stub roadie CLI -----------------------------------------------------------
# Mirrors Roadie 0.87: logs go to stderr, `client add` prints only the key on
# stdout, the client registry lives in the data dir, and pi-agent-dir writes
# models.json for the given base URL.
STUB="$TMP/stub/roadie"
mkdir -p "$(dirname "$STUB")"
cat > "$STUB" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ROADIE_STUB_LOG"
reg="$ROADIE_DATA_DIR/pool-clients.txt"
[ "$1 $2" = "credentials client" ] || exit 2
case "$3" in
  list)
    if [ -s "$reg" ]; then
      while read -r name; do printf '│  16:24 CLI      %s  pools: shared  created 2026-11-24T00:00:00.000Z\n' "$name" >&2; done < "$reg"
    else
      printf '│  16:24 CLI      No pool clients registered.\n' >&2
    fi ;;
  add)
    mkdir -p "$ROADIE_DATA_DIR"
    grep -qx "$4" "$reg" 2>/dev/null && { echo "pool client $4 already exists" >&2; exit 1; }
    echo "$4" >> "$reg"
    n=$(( $(cat "$ROADIE_DATA_DIR/key-seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ROADIE_DATA_DIR/key-seq"
    printf '│  16:24 CLI      Registered pool client %s (pools: shared)\n' "$4" >&2
    printf 'rpc_stubkey000000000000000000%04d\n' "$n"
    printf '│  16:24 CLI      Restart Roadie so the pool proxy starts for registered clients.\n' >&2 ;;
  remove)
    grep -qx "$4" "$reg" 2>/dev/null || exit 1
    grep -vx "$4" "$reg" > "$reg.new"; mv "$reg.new" "$reg" ;;
  pi-agent-dir)
    [ "${ROADIE_STUB_NO_ROTATION:-false}" = true ] && { echo "Pools shared have no rotation" >&2; exit 1; }
    mkdir -p "$4"
    printf '{"providers":{"roadie":{"baseUrl":"%s"}}}\n' "$6" > "$4/models.json" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$STUB"
ROADIE_BIN="$STUB"
export ROADIE_STUB_LOG="$TMP/roadie.log"
AGENT_DIR="$ROADIE_DATA_DIR/pool-clients/homeboy-daemon/pi-agent"

reset() { : > "$TMP/warn.log"; : > "$ROADIE_STUB_LOG"; PENDING_ITEMS=(); UPDATED_ITEMS=(); }
key_of() { sed -n 's/^ROADIE_PI_KEY=//p' "$ENV_FILE"; }
mode_of() { file_mode "$1"; }
reconcile() { bridge_pool_client_reconcile homeboy-daemon "$ENV_FILE"; }

echo "==> applicability and the fixed pool proxy port"
bridge_pool_client_applicable; check $? "a managed VPS install with a local pool wants a daemon pool client"
[ "$(_roadie_pool_proxy_port)" = 47120 ]; check $? "default instance claims the default proxy port"
( ROADIE_UNIT=roadie-second.service; ! _roadie_pool_proxy_port >/dev/null ); check $? "a named instance gets no port unless the operator sets one"
( ROADIE_UNIT=roadie-second.service ROADIE_POOL_PROXY_PORT=47121; [ "$(_roadie_pool_proxy_port)" = 47121 ] ); check $? "an operator port is honored on a named instance"
( ROADIE_POOL_URL=http://pool.example:47120; ! bridge_pool_client_applicable ); check $? "a remote-pool bot gets no local daemon client"
( LOCAL_MODE=true; ! bridge_pool_client_applicable ); check $? "a local install gets no daemon client"
( ROADIE_POOL_PROXY_PORT=99999; ! _roadie_pool_proxy_port >/dev/null 2>&1 ); check $? "an out-of-range port is refused"

echo "==> roadie.service renders ROADIE_POOL_PROXY_PORT once"
cat > "$SYSTEMD_UNIT_DIR/roadie.service" <<EOF
[Service]
User=$SERVICE_USER
WorkingDirectory=$TMP/site
Environment=HOME=$TMP/home
Environment=PATH=/usr/bin:/bin
Environment=ROADIE_DATA_DIR=$TMP/home/.roadie
Environment=ROADIE_POOL_PROXY_PORT=1234
ExecStart=/usr/bin/roadie --data-dir $TMP/home/.roadie --auto-restart
EOF
bridge_update_systemd >/dev/null 2>&1
[ "$(grep -c '^Environment=ROADIE_POOL_PROXY_PORT=' "$SYSTEMD_UNIT_DIR/roadie.service")" -eq 1 ]; check $? "exactly one ROADIE_POOL_PROXY_PORT"
grep -qx 'Environment=ROADIE_POOL_PROXY_PORT=47120' "$SYSTEMD_UNIT_DIR/roadie.service"; check $? "stale port replaced by the resolved one"
unset ROADIE_POOL_PROXY_PORT
_roadie_resolve_instance 2>/dev/null
[ "${ROADIE_POOL_PROXY_PORT:-}" = 47120 ]; check $? "a later upgrade adopts the port from the unit"
unset ROADIE_POOL_PROXY_PORT
ROADIE_BIN="$STUB"  # bridge_update_systemd re-resolves the real binary

echo "==> daemon unit loads the env file, never the key"
unit="$(homeboy_daemon_render_systemd_service)"
grep -qxF "EnvironmentFile=-$ENV_FILE" <<< "$unit"; check $? "unit carries EnvironmentFile=-<pi.env>"
! grep -q 'ROADIE_PI_KEY\|PI_CODING_AGENT_DIR' <<< "$unit"; check $? "unit never inlines the key or agent dir"
unit="$(ROADIE_POOL_URL=http://pool.example:47120 homeboy_daemon_render_systemd_service)"
! grep -q '^EnvironmentFile=.*pi.env' <<< "$unit"; check $? "remote-pool bot unit has no pi.env"

echo "==> dry run writes nothing and calls no CLI"
reset
DRY_RUN=true reconcile >/dev/null
[ ! -e "$ENV_FILE" ] && [ ! -e "$AGENT_DIR" ]; check $? "no env file or agent dir"
[ ! -s "$ROADIE_STUB_LOG" ]; check $? "roadie CLI not invoked"

echo "==> first run registers the client and writes a 0600 env file"
reset
reconcile
grep -qx 'credentials client add homeboy-daemon --pools shared' "$ROADIE_STUB_LOG"; check $? "client registered on the shared pool"
grep -qx "credentials client pi-agent-dir $AGENT_DIR --base-url http://127.0.0.1:47120" "$ROADIE_STUB_LOG"; check $? "agent dir written against the proxy port"
[ "$(key_of)" = rpc_stubkey0000000000000000000001 ]; check $? "env file carries the printed key"
grep -qx "PI_CODING_AGENT_DIR=$AGENT_DIR" "$ENV_FILE"; check $? "env file carries PI_CODING_AGENT_DIR"
[ "$(mode_of "$ENV_FILE")" = 600 ]; check $? "env file is 0600"
[ "$(mode_of "$(dirname "$ENV_FILE")")" = 700 ]; check $? "env dir is 0700"
[ "$BRIDGE_POOL_CLIENT_ENV_CHANGED" = true ]; check $? "change reported so the daemon restarts"
! grep -rq rpc_stubkey "$SYSTEMD_UNIT_DIR"; check $? "key absent from every unit"

echo "==> re-run is idempotent and never rotates"
reset
cp "$ENV_FILE" "$TMP/env.before"
reconcile
! grep -q 'client add\|client remove' "$ROADIE_STUB_LOG"; check $? "no add/remove when registered with a key file"
cmp -s "$ENV_FILE" "$TMP/env.before"; check $? "env file byte-identical"
[ "$BRIDGE_POOL_CLIENT_ENV_CHANGED" = false ]; check $? "no restart requested"
grep -q 'client pi-agent-dir' "$ROADIE_STUB_LOG"; check $? "agent dir still refreshed for new rotations"

echo "==> a missing key file re-registers the client"
reset
rm -f "$ENV_FILE"
reconcile
grep -qx 'credentials client remove homeboy-daemon' "$ROADIE_STUB_LOG"; check $? "stale registration removed"
grep -qx 'credentials client add homeboy-daemon --pools shared' "$ROADIE_STUB_LOG"; check $? "client re-added"
[ "$(key_of)" = rpc_stubkey0000000000000000000002 ]; check $? "new key stored"

echo "==> a key file without a registration is replaced"
reset
: > "$ROADIE_DATA_DIR/pool-clients.txt"
reconcile
! grep -q 'client remove' "$ROADIE_STUB_LOG"; check $? "nothing to remove"
[ "$(key_of)" = rpc_stubkey0000000000000000000003 ]; check $? "orphan key replaced"

echo "==> failures are reported, not fatal"
reset
cp "$ENV_FILE" "$TMP/env.before"
ROADIE_STUB_NO_ROTATION=true reconcile; rc=$?
[ "$rc" -eq 0 ]; check $? "a pool without rotations does not fail the run"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -q 'Pi agent dir'; check $? "missing agent dir is pending"
cmp -s "$ENV_FILE" "$TMP/env.before"; check $? "key kept when only the agent dir fails"
reset
( WP_CODING_AGENTS_TEST_EUID=1000; reconcile; printf '%s\n' "${PENDING_ITEMS[@]}" ) | grep -q 'root'; check $? "non-root run defers to root"
[ ! -s "$ROADIE_STUB_LOG" ]; check $? "non-root run calls no CLI"

echo "==> verify: local Cook provider route status"
cat > "$TMP/hb.service" <<EOF
[Service]
EnvironmentFile=-$ENV_FILE
EOF
msg="$(homeboy_daemon_pi_route_status "$TMP/hb.service")"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'authenticated' <<< "$msg"; check $? "converged route is authenticated"
mv "$ENV_FILE" "$TMP/env.moved"
msg="$(homeboy_daemon_pi_route_status "$TMP/hb.service")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'local Cook provider route unauthenticated: .*missing' <<< "$msg"; check $? "missing env file is unauthenticated"
sed '/^ROADIE_PI_KEY=/d' "$TMP/env.moved" > "$ENV_FILE"; chmod 600 "$ENV_FILE"
msg="$(homeboy_daemon_pi_route_status "$TMP/hb.service")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'unauthenticated: .*no ROADIE_PI_KEY' <<< "$msg"; check $? "missing key is unauthenticated"
cp "$TMP/env.moved" "$ENV_FILE"; chmod 644 "$ENV_FILE"
homeboy_daemon_pi_route_status "$TMP/hb.service" >/dev/null; [ $? -eq 1 ]; check $? "world-readable key file fails"
printf '[Service]\nExecStart=/bin/true\n' > "$TMP/hb-bare.service"
msg="$(homeboy_daemon_pi_route_status "$TMP/hb-bare.service")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'unauthenticated: .*loads no Roadie pool client' <<< "$msg"; check $? "unit without the env file is unauthenticated"

echo "==> daemon reconcile wires the client and restarts on a new key"
reset
chmod 600 "$ENV_FILE"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\ncase "$1" in is-active) exit 0;; show) echo 0;; esac\nexit 0\n' "$TMP/systemctl.log" > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"
unset -f systemctl
PATH="$TMP/bin:$PATH"
_homeboy_daemon_status_json() { printf '{"data":{"active_jobs":[],"running":true,"fresh":true,"daemon":{"pid":0}}}\n'; }
homeboy_daemon_service_reconcile >/dev/null 2>&1
grep -qxF "EnvironmentFile=-$ENV_FILE" "$(homeboy_daemon_unit_path)"; check $? "installed unit loads the env file"
: > "$TMP/systemctl.log"
rm -f "$ENV_FILE"
homeboy_daemon_service_reconcile >/dev/null 2>&1
grep -qx 'restart homeboy-daemon.service' "$TMP/systemctl.log"; check $? "idle daemon restarted onto the new key"
: > "$TMP/systemctl.log"
homeboy_daemon_service_reconcile >/dev/null 2>&1
! grep -q '^restart' "$TMP/systemctl.log"; check $? "converged re-run does not restart"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: tests/homeboy-daemon-pool-client.sh ($FAIL failed, $PASS passed)"
  exit 1
fi
echo "PASS: tests/homeboy-daemon-pool-client.sh ($PASS assertions)"
