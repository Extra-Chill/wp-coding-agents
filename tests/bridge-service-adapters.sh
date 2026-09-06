#!/bin/bash
# Plan fixtures for optional bridge and service ownership.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/desired-state-reconciler.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/services/datamachine-worker.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/services/wordpress-service.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/bridge-service-adapters.sh"

log() { :; }
warn() { :; }
error() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SITE_PATH="$TMP/site"
SERVICE_HOME="$TMP/home"
LOCAL_MODE=true
PLATFORM=mac
EXTERNAL_WORDPRESS=false
RUNTIME=opencode
INSTALL_CHAT=true
CHAT_BRIDGE=kimaki
WORDPRESS_SERVICE_REQUEST=enabled
DATAMACHINE_WORKER_REQUEST=enabled
WORDPRESS_SERVICE_LAUNCHD_DIR="$TMP/LaunchAgents"
# shellcheck disable=SC2034 # Consumed by the sourced worker service.
DATAMACHINE_WORKER_LAUNCHD_DIR="$TMP/LaunchAgents"
mkdir -p "$SITE_PATH" "$SERVICE_HOME"

reconciler_plan_reset
bridge_service_adapters_plan "$INSTALLATION_OPERATION_SETUP"
setup_records="${RECONCILER_PLAN_RECORDS[*]}"
[ "$setup_records" = 'bridges.kimaki services.wordpress services.datamachine-worker' ] || error "setup records were not derived from opt-in state: $setup_records"

# Upgrade detects the installed bridge while service records come from the same
# persisted opt-in state, so both entrypoints converge on the same records.
bridge_detect_local() { printf 'kimaki\n'; }
CHAT_BRIDGE=""
reconciler_plan_reset
bridge_service_adapters_plan "$INSTALLATION_OPERATION_UPGRADE"
upgrade_records="${RECONCILER_PLAN_RECORDS[*]}"
[ "$upgrade_records" = "$setup_records" ] || error "setup and upgrade derived different records: $setup_records != $upgrade_records"

# No bridge, no persisted service state, and no optional-service request means
# no core reconciliation branch and no filesystem/service action.
INSTALL_CHAT=false
CHAT_BRIDGE=""
unset WORDPRESS_SERVICE_REQUEST DATAMACHINE_WORKER_REQUEST
reconciler_plan_reset
bridge_service_adapters_plan "$INSTALLATION_OPERATION_SETUP"
[ "${#RECONCILER_PLAN_RECORDS[@]}" -eq 0 ] || error "absent optional integrations added plan records"
[ ! -e "$WORDPRESS_SERVICE_LAUNCHD_DIR" ] || error "absent optional integrations created launchd state"
[ ! -e "$SERVICE_HOME/.config" ] || error "absent optional integrations created persisted state"

# Upgrade must honor the persisted disabled-chat intent even if a bridge binary
# remains detectable on disk.
reconciler_plan_reset
bridge_service_adapters_plan "$INSTALLATION_OPERATION_UPGRADE"
[ "${#RECONCILER_PLAN_RECORDS[@]}" -eq 0 ] || error "disabled chat was rediscovered during upgrade"

# External WordPress owns neither local service, even when callers supplied an
# opt-in request. The bridge remains independently eligible.
EXTERNAL_WORDPRESS=true
INSTALL_CHAT=true
CHAT_BRIDGE=kimaki
WORDPRESS_SERVICE_REQUEST=enabled
DATAMACHINE_WORKER_REQUEST=enabled
reconciler_plan_reset
bridge_service_adapters_plan "$INSTALLATION_OPERATION_SETUP"
[ "${RECONCILER_PLAN_RECORDS[*]}" = bridges.kimaki ] || error "external WordPress planned local services"

# Managed unit runtime health is reported, never acted on (#576). A unit whose
# file is already correct but which has been dead for weeks is the quietest
# failure mode, so health must not depend on the file having changed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  show)
    case "$*" in
      *ActiveState*) printf '%s\n' "${FAKE_ACTIVE:-active}" ;;
      *ActiveEnterTimestamp*) printf '%s\n' "${FAKE_SINCE:-}" ;;
      *) printf '\n' ;;
    esac
    ;;
  is-enabled) printf '%s\n' "${FAKE_ENABLED:-enabled}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
PATH="$TMP/bin:$PATH"
export PATH

# Capture warnings instead of discarding them.
CAPTURED=""
warn() { CAPTURED="$CAPTURED$1
"; }

# Healthy unit: no warning, no summary entry.
HEALTH_WARNINGS=()
CAPTURED=""
export FAKE_ACTIVE=active FAKE_ENABLED=enabled FAKE_SINCE=""
_report_systemd_unit_health kimaki.service kimaki.service
[ "${#HEALTH_WARNINGS[@]}" -eq 0 ] || error "active unit produced a health warning"

# Failed unit: warns and records for the summary.
HEALTH_WARNINGS=()
CAPTURED=""
export FAKE_ACTIVE=failed FAKE_ENABLED=enabled FAKE_SINCE="Wed 2026-08-05 14:46:59 UTC"
_report_systemd_unit_health kimaki.service kimaki.service
[ "${#HEALTH_WARNINGS[@]}" -eq 1 ] || error "failed unit was not recorded for the summary"
case "${HEALTH_WARNINGS[0]}" in
  *failed*kimaki.service*) : ;;
  *) error "failed-unit summary entry did not name the unit and state: ${HEALTH_WARNINGS[0]}" ;;
esac
case "$CAPTURED" in
  *"did not start it"*) : ;;
  *) error "failed unit did not state that the upgrade left it alone" ;;
esac

# Enabled but inactive is a real finding.
HEALTH_WARNINGS=()
CAPTURED=""
export FAKE_ACTIVE=inactive FAKE_ENABLED=enabled
_report_systemd_unit_health kimaki.service kimaki.service
[ "${#HEALTH_WARNINGS[@]}" -eq 1 ] || error "enabled-but-inactive unit was not recorded"

# Deliberately disabled units stay quiet.
HEALTH_WARNINGS=()
CAPTURED=""
export FAKE_ACTIVE=inactive FAKE_ENABLED=disabled
_report_systemd_unit_health kimaki.service kimaki.service
[ "${#HEALTH_WARNINGS[@]}" -eq 0 ] || error "disabled unit produced a health warning"

# Health is reported even when the unit file is byte-identical, which is the
# path that hid a four-week outage.
HEALTH_WARNINGS=()
CAPTURED=""
UPDATED_ITEMS=()
DRY_RUN=false
TIMESTAMP=test
UNCHANGED_UNIT="$TMP/kimaki.service"
printf '[Service]\nExecStart=/usr/bin/kimaki\n' > "$UNCHANGED_UNIT"
export FAKE_ACTIVE=failed FAKE_ENABLED=enabled
_smart_update_systemd_unit "$UNCHANGED_UNIT" "$(cat "$UNCHANGED_UNIT")" kimaki.service
[ "${#HEALTH_WARNINGS[@]}" -eq 1 ] || error "unchanged unit file suppressed the health report"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || error "unchanged unit file was reported as updated"

echo "PASS: tests/bridge-service-adapters.sh"
