#!/bin/bash
# Supervised Homeboy daemon unit (#659): rendering, applicability, adoption of
# an unsupervised daemon, and binary convergence that never interrupts work.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/homeboy.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/services/homeboy-daemon.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
LOGGED=""
log() { LOGGED="$LOGGED$1
"; }
warn() { LOGGED="$LOGGED$1
"; }

unset HOMEBOY_DATA_DIR
SERVICE_USER=wpagent
SERVICE_HOME="$TMP/home"
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
DRY_RUN=false
TIMESTAMP=test
UPDATED_ITEMS=()
HOMEBOY_DAEMON_SYSTEMD_DIR="$TMP/systemd"
WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMP/prefix/wp-coding-agents/bin/homeboy"
mkdir -p "$SERVICE_HOME" "$HOMEBOY_DAEMON_SYSTEMD_DIR" "$(dirname "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN")"

# --- Rendering ---------------------------------------------------------------
bridge_load roadie
ROADIE_SYSTEM_PREFIX="$TMP/roadie-prefix"
ROADIE_LOCK_PORT=29988
unit="$(homeboy_daemon_render_systemd_service)"
grep -qx "Environment=HOMEBOY_SESSION_SEND_COMMAND=$ROADIE_SYSTEM_PREFIX/bin/roadie send" <<< "$unit" || fail "unit does not carry the bridge session sender"
grep -qx "Environment=ROADIE_SERVICE_TOKEN_FILE=/etc/wp-coding-agents/roadie/send-token" <<< "$unit" || fail "unit does not carry sender authentication"
grep -q "PATH=.*$ROADIE_SYSTEM_PREFIX/bin" <<< "$unit" || fail "sender binary directory is not on PATH"
unset -f bridge_session_sender_command bridge_session_sender_env
unit="$(homeboy_daemon_render_systemd_service)"
! grep -q '^Environment=HOMEBOY_SESSION_SEND_COMMAND=' <<< "$unit" || fail "unit sets a sender without a bridge"
grep -qx "User=wpagent" <<< "$unit" || fail "unit does not run as the service user"
grep -qx "Environment=HOME=$SERVICE_HOME" <<< "$unit" || fail "unit HOME is not the service home"
grep -qx "ExecStart=$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN daemon serve" <<< "$unit" || fail "unit does not serve the managed binary in the foreground"
grep -qx "Restart=always" <<< "$unit" || fail "unit is not always restarted"
grep -qx "StartLimitIntervalSec=0" <<< "$unit" || fail "unit can give up while another daemon owns the lock"
grep -qx "WantedBy=multi-user.target" <<< "$unit" || fail "unit is not enabled at boot"
case "$unit" in *roadie*|*kimaki*) fail "daemon unit names a chat bridge" ;; esac
grep -q "HOMEBOY_DATA_DIR" <<< "$unit" && fail "unit sets HOMEBOY_DATA_DIR without a workspace root"
unit="$(HOMEBOY_DATA_DIR=/srv/workspace/.homeboy homeboy_daemon_render_systemd_service)"
grep -qx "Environment=HOMEBOY_DATA_DIR=/srv/workspace/.homeboy" <<< "$unit" || fail "unit does not carry the workspace Homeboy data root"

# --- Applicability -------------------------------------------------------------
homeboy_daemon_service_applicable && fail "unit applies before the managed binary exists"
printf '#!/bin/sh\n' > "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN"
chmod +x "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN"
homeboy_daemon_service_applicable || fail "unit does not apply to a managed VPS install"
LOCAL_MODE=true homeboy_daemon_service_applicable && fail "unit applies to a local install"
EXTERNAL_WORDPRESS=true homeboy_daemon_service_applicable && fail "unit applies to external WordPress"
SERVICE_USER=root homeboy_daemon_service_applicable && fail "unit applies without a service-owned binary"

# --- Fakes: systemctl and daemon status ----------------------------------------
# The fake daemon is described by FAKE_RUNNING, FAKE_FRESH, FAKE_JOBS, and
# FAKE_DAEMON_PID; the unit by FAKE_UNIT_ACTIVE and FAKE_UNIT_PID.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
  show)
    case "$*" in
      *MainPID*) printf '%s\n' "${FAKE_UNIT_PID:-0}" ;;
      *ActiveState*) printf 'active\n' ;;
      *) printf '\n' ;;
    esac ;;
  is-active) [ "${FAKE_UNIT_ACTIVE:-false}" = true ] ;;
  is-enabled) printf 'enabled\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
PATH="$TMP/bin:$PATH"
export PATH SYSTEMCTL_LOG="$TMP/systemctl.log"

_homeboy_daemon_status_json() {
  python3 - <<'PY'
import json, os
jobs = [{"job_id": str(i)} for i in range(int(os.environ.get("FAKE_JOBS", "0")))]
print(json.dumps({"data": {
    "active_jobs": jobs,
    "running": os.environ.get("FAKE_RUNNING", "true") == "true",
    "fresh": os.environ.get("FAKE_FRESH", "true") == "true",
    "daemon": {"pid": int(os.environ.get("FAKE_DAEMON_PID", "4242"))},
}}))
PY
}
STOPPED=""
_homeboy_daemon_as_service_user() { STOPPED="$STOPPED$*;"; }
export FAKE_RUNNING FAKE_FRESH FAKE_JOBS FAKE_DAEMON_PID FAKE_UNIT_ACTIVE FAKE_UNIT_PID

reset() {
  : > "$SYSTEMCTL_LOG"; STOPPED=""; LOGGED=""
  FAKE_RUNNING=true FAKE_FRESH=true FAKE_JOBS=0 FAKE_DAEMON_PID=4242 FAKE_UNIT_ACTIVE=false FAKE_UNIT_PID=0
}

# --- Fresh install: an idle unsupervised daemon is handed over -----------------
reset
homeboy_daemon_service_reconcile
[ -f "$HOMEBOY_DAEMON_SYSTEMD_DIR/homeboy-daemon.service" ] || fail "unit file was not written"
[ "$STOPPED" = "daemon stop;" ] || fail "idle unsupervised daemon was not stopped for adoption (got '$STOPPED')"
grep -qx "enable --now homeboy-daemon.service" "$SYSTEMCTL_LOG" || fail "unit was not enabled and started"

# --- A busy unsupervised daemon is never stopped --------------------------------
rm -f "$HOMEBOY_DAEMON_SYSTEMD_DIR/homeboy-daemon.service"
reset; FAKE_JOBS=1
homeboy_daemon_service_reconcile
[ -z "$STOPPED" ] || fail "busy unsupervised daemon was stopped"
grep -qx "enable --now homeboy-daemon.service" "$SYSTEMCTL_LOG" || fail "unit was not enabled while waiting for the busy daemon"
case "$LOGGED" in *"take over when it exits"*) : ;; *) fail "busy handover was not reported" ;; esac

# --- Supervised, fresh binary: nothing to do ------------------------------------
reset; FAKE_UNIT_ACTIVE=true FAKE_UNIT_PID=4242
homeboy_daemon_service_reconcile
grep -q "^restart" "$SYSTEMCTL_LOG" && fail "fresh supervised daemon was restarted"
[ -z "$STOPPED" ] || fail "supervised daemon was stopped"

# --- Supervised, replaced binary, idle: restarted onto the new binary -----------
reset; FAKE_UNIT_ACTIVE=true FAKE_UNIT_PID=4242 FAKE_FRESH=false
homeboy_daemon_service_reconcile
grep -qx "restart homeboy-daemon.service" "$SYSTEMCTL_LOG" || fail "idle stale daemon was not restarted"

# --- Supervised, replaced binary, busy: left serving its jobs -------------------
reset; FAKE_UNIT_ACTIVE=true FAKE_UNIT_PID=4242 FAKE_FRESH=false FAKE_JOBS=2
homeboy_daemon_service_reconcile
grep -q "^restart" "$SYSTEMCTL_LOG" && fail "busy stale daemon was restarted under in-flight work"
case "$LOGGED" in *"jobs in flight"*) : ;; *) fail "deferred restart was not reported" ;; esac

# --- Unknown daemon status is treated as busy -----------------------------------
reset
_homeboy_daemon_status_json() { return 1; }
homeboy_daemon_idle && fail "unknown daemon status was treated as idle"


# --- Homeboy data root migration (#710) -----------------------------------------
_homeboy_daemon_status_json() {
  python3 - <<'PY'
import json, os
jobs = [{"job_id": str(i)} for i in range(int(os.environ.get("FAKE_JOBS", "0")))]
print(json.dumps({"data": {"active_jobs": jobs, "running": os.environ.get("FAKE_RUNNING", "true") == "true", "fresh": True, "daemon": {"pid": 0}}}))
PY
}
legacy="$SERVICE_HOME/.local/share/homeboy"
new_root="$TMP/workspace/.homeboy"
seed_legacy() {
  rm -rf "$legacy" "$TMP/workspace"; mkdir -p "$legacy/runtime"
  sqlite3 "$legacy/homeboy.sqlite" 'CREATE TABLE t (x); INSERT INTO t VALUES (1);'
  echo kept > "$legacy/runtime/marker"
}

# No variable: nothing happens.
seed_legacy; reset; HOMEBOY_DATA_DIR=""
homeboy_data_dir_migrate
[ -d "$legacy" ] && [ ! -L "$legacy" ] || fail "migration ran without HOMEBOY_DATA_DIR"

# Non-root: deferred and the variable cleared so no unit points at an empty store.
seed_legacy; reset; HOMEBOY_DATA_DIR="$new_root"
_homeboy_data_dir_is_root() { return 1; }
homeboy_data_dir_migrate
[ -z "$HOMEBOY_DATA_DIR" ] || fail "deferred migration left HOMEBOY_DATA_DIR set"
[ ! -L "$legacy" ] || fail "non-root migration moved the store"

# Dry run: reported, nothing moved, variable cleared.
seed_legacy; reset; HOMEBOY_DATA_DIR="$new_root"
_homeboy_data_dir_is_root() { return 0; }
DRY_RUN=true homeboy_data_dir_migrate
[ -z "$HOMEBOY_DATA_DIR" ] && [ ! -L "$legacy" ] || fail "dry run moved the store or kept the variable"

# Busy daemon: deferred.
seed_legacy; reset; HOMEBOY_DATA_DIR="$new_root"; FAKE_RUNNING=true FAKE_JOBS=1
homeboy_data_dir_migrate
[ -z "$HOMEBOY_DATA_DIR" ] && [ ! -L "$legacy" ] || fail "migration ran under in-flight daemon work"

# Root, idle: store moved, legacy path becomes a symlink, data intact.
seed_legacy; reset; HOMEBOY_DATA_DIR="$new_root"
fuser() { return 1; }
homeboy_data_dir_migrate
[ "$HOMEBOY_DATA_DIR" = "$new_root" ] || fail "successful migration cleared HOMEBOY_DATA_DIR"
[ -L "$legacy" ] && [ "$(readlink "$legacy")" = "$new_root" ] || fail "legacy path is not a symlink to the new root"
[ "$(cat "$new_root/runtime/marker")" = kept ] || fail "store contents were not carried over"
[ "$(sqlite3 "$new_root/homeboy.sqlite" 'SELECT x FROM t;')" = 1 ] || fail "sqlite store was not carried over"
grep -qx "stop homeboy-daemon.service" "$SYSTEMCTL_LOG" || fail "daemon was not stopped before the move"

# Already migrated: idempotent no-op.
reset; HOMEBOY_DATA_DIR="$new_root"
homeboy_data_dir_migrate
[ "$HOMEBOY_DATA_DIR" = "$new_root" ] && [ -L "$legacy" ] || fail "rerun on a migrated host was not a no-op"
grep -q "^stop" "$SYSTEMCTL_LOG" && fail "rerun on a migrated host stopped the daemon"

# Both locations populated: never clobber, stay on legacy.
seed_legacy; mkdir -p "$new_root"; echo other > "$new_root/x"; reset; HOMEBOY_DATA_DIR="$new_root"
homeboy_data_dir_migrate
[ -z "$HOMEBOY_DATA_DIR" ] && [ ! -L "$legacy" ] && [ -f "$new_root/x" ] || fail "migration clobbered an existing target"

# --- Data root resolution follows the configured workspace (#710) --------------
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/source-policy.sh"
HOMEBOY_DATA_DIR="" DM_WORKSPACE_DIR=""
source_policy_resolve_homeboy_data_dir
[ -z "$HOMEBOY_DATA_DIR" ] || fail "data root resolved without a workspace"
HOMEBOY_DATA_DIR="" DM_WORKSPACE_DIR=/srv/ws
source_policy_resolve_homeboy_data_dir
[ "$HOMEBOY_DATA_DIR" = /srv/ws/.homeboy ] || fail "data root does not follow the workspace"
HOMEBOY_DATA_DIR=/data/hb DM_WORKSPACE_DIR=/srv/ws
source_policy_resolve_homeboy_data_dir
[ "$HOMEBOY_DATA_DIR" = /data/hb ] || fail "operator-set data root was overridden"

echo "PASS: tests/homeboy-daemon-service.sh"
