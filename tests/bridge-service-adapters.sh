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

echo "PASS: tests/bridge-service-adapters.sh"
