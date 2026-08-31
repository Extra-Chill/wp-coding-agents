#!/bin/bash
# End-to-end fixture for the shared setup/upgrade convergence graph.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT_DIR/lib/desired-state-reconciler.sh"
source "$ROOT_DIR/lib/convergence-orchestrator.sh"
source "$ROOT_DIR/lib/integration-adapters.sh"
source "$ROOT_DIR/lib/runtime-guidance-desired-state.sh"
source "$ROOT_DIR/lib/bridge-service-adapters.sh"

log() { :; }
warn() { :; }
error() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
guidance_sync_all() { printf 'guidance\n' >> "$TRACE"; }
runtime_install() { printf 'runtime-install\n' >> "$TRACE"; }
runtime_discover_dm_paths() { printf 'runtime-paths\n' >> "$TRACE"; }
runtime_generate_config() { printf 'runtime-config\n' >> "$TRACE"; }
runtime_install_hooks() { printf 'runtime-hooks\n' >> "$TRACE"; }
runtime_generate_instructions() { printf 'runtime-instructions\n' >> "$TRACE"; }
runtime_merge_mcp_servers() { printf 'runtime-mcp\n' >> "$TRACE"; }
runtime_guard_sync() { printf 'runtime-guard\n' >> "$TRACE"; }
external_wordpress_project_context() { printf 'runtime-context\n' >> "$TRACE"; }
bridge_detect_local() { printf 'kimaki\n'; }
bridge_detect_vps() { printf 'kimaki\n'; }
bridge_file() { return 0; }
bridge_load() { :; }
bridge_has_hook() { return 0; }
bridge_install() { printf 'bridge\n' >> "$TRACE"; }
bridge_sync_config() { printf 'bridge\n' >> "$TRACE"; }
bridge_update_launchd() { :; }
bridge_update_systemd() { :; }
wordpress_service_state_file() { printf '%s/wordpress-state' "$TMP"; }
datamachine_worker_state_file() { printf '%s/worker-state' "$TMP"; }
wordpress_service_launchd_dir() { printf '%s/LaunchAgents' "$TMP"; }
datamachine_worker_launchd_dir() { printf '%s/LaunchAgents' "$TMP"; }
wordpress_service_label() { printf wordpress; }
datamachine_worker_launchd_label() { printf worker; }
datamachine_worker_systemd_dir() { printf '%s/units' "$TMP"; }
wordpress_service_reconcile() { printf 'wordpress-service\n' >> "$TRACE"; }
datamachine_worker_reconcile() { printf 'worker-service\n' >> "$TRACE"; }
wordpress_service_desired_state() { :; }
datamachine_worker_desired_state() { :; }

graph_for() {
  local operation="$1"
  installation_profile_normalize "$operation"
  convergence_plan "$operation"
  printf '%s\n' "${RECONCILER_PLAN_RECORDS[@]:-}"
}

for mode in local vps workspace owned; do
  SITE_PATH="$TMP/$mode"; mkdir -p "$SITE_PATH"
  LOCAL_MODE=false; EXTERNAL_WORDPRESS=false; IS_STUDIO=false; SOURCE_MODE=workspace
  [ "$mode" = local ] && LOCAL_MODE=true
  [ "$mode" = workspace ] && IS_STUDIO=true
  [ "$mode" = owned ] && SOURCE_MODE=owned
  RUNTIME=opencode; CHAT_BRIDGE=kimaki; HOMEBOY_MODE=disabled; INSTALL_CHAT=true
  WORDPRESS_SERVICE_REQUEST=""; DATAMACHINE_WORKER_REQUEST=""; TRACE="$TMP/$mode.trace"
  setup_graph="$(graph_for "$INSTALLATION_OPERATION_SETUP")"
  upgrade_graph="$(graph_for "$INSTALLATION_OPERATION_UPGRADE")"
  [ "$setup_graph" = "$upgrade_graph" ] || error "$mode setup and upgrade graphs differ"
done

# External mode retains only runtime-local records and never creates optional
# local integration/service records.
SITE_PATH="$TMP/external"; mkdir -p "$SITE_PATH"; LOCAL_MODE=true; EXTERNAL_WORDPRESS=true
IS_STUDIO=false; SOURCE_MODE=workspace; RUNTIME=opencode; CHAT_BRIDGE=kimaki; HOMEBOY_MODE=auto
INSTALL_CHAT=true; TRACE="$TMP/external.trace"
external_graph="$(graph_for "$INSTALLATION_OPERATION_SETUP")"
case "$external_graph" in *"services."*|*"integrations."*) error "external graph included local optional effect" ;; esac

# A complete run has one record and one effect per runtime capability; optional
# integrations absent from the profile do not manufacture work.
EXTERNAL_WORDPRESS=false; HOMEBOY_MODE=disabled; INSTALL_CHAT=false
TRACE="$TMP/local.trace"
installation_profile_normalize "$INSTALLATION_OPERATION_SETUP"
convergence_run "$INSTALLATION_OPERATION_SETUP"
for effect in guidance runtime-install runtime-paths runtime-config runtime-hooks runtime-instructions runtime-mcp runtime-guard; do
  [ "$(grep -c "^$effect$" "$TRACE")" -eq 1 ] || error "$effect did not execute exactly once"
done
[ ! -s "$TMP/external.trace" ] || error "external fixture unexpectedly executed local effects"

echo "PASS: shared convergence derives equivalent graphs and executes no duplicate optional effects"
