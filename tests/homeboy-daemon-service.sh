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
unit="$(homeboy_daemon_render_systemd_service)"
grep -qx "User=wpagent" <<< "$unit" || fail "unit does not run as the service user"
grep -qx "Environment=HOME=$SERVICE_HOME" <<< "$unit" || fail "unit HOME is not the service home"
grep -qx "ExecStart=$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN daemon serve" <<< "$unit" || fail "unit does not serve the managed binary in the foreground"
grep -qx "Restart=always" <<< "$unit" || fail "unit is not always restarted"
grep -qx "StartLimitIntervalSec=0" <<< "$unit" || fail "unit can give up while another daemon owns the lock"
grep -qx "WantedBy=multi-user.target" <<< "$unit" || fail "unit is not enabled at boot"
case "$unit" in *roadie*|*kimaki*) fail "daemon unit names a chat bridge" ;; esac

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

echo "PASS: tests/homeboy-daemon-service.sh"
