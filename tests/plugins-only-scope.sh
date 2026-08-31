#!/bin/bash
# tests/plugins-only-scope.sh — --plugins-only must not cross into service state.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$ROOT_DIR/upgrade.sh"

require_source() {
  local pattern="$1" description="$2"
  grep -Fq -- "$pattern" "$UPGRADE" || {
    echo "FAIL: missing $description" >&2
    exit 1
  }
}

require_file_source() {
  local file="$1" pattern="$2" description="$3"
  grep -Fq -- "$pattern" "$file" || {
    echo "FAIL: missing $description" >&2
    exit 1
  }
}

require_source 'plugins)   [ "$PLUGINS_ONLY" = true ]; return $? ;;' "plugins-only plugin phase"
require_source 'reconciliation|transport|systemd|patch) [ "$RECONCILE_SERVICES_ONLY" = true ]; return $? ;;' "separate reconciliation phases"
require_source 'convergence_run "$INSTALLATION_OPERATION_UPGRADE"' "shared full reconciliation entrypoint"
require_file_source "$ROOT_DIR/lib/convergence-orchestrator.sh" 'integration_adapters_plan' "integration adapter composition"
require_file_source "$ROOT_DIR/lib/convergence-orchestrator.sh" 'bridge_service_adapters_plan' "bridge/service adapter composition"
require_source './upgrade.sh --reconcile-services' "explicit reconciliation command"
require_source 'if [ "$PLUGINS_ONLY" != true ]; then' "plugins-only source-policy mutation guard"
require_source 'detect_plugins_only_environment' "narrow plugin-only environment detection"
require_source 'installation_profile_normalize "$INSTALLATION_OPERATION_PLUGINS_ONLY"' "credential-free plugins-only profile normalization"
require_source 'reconcile_installed_plugins() {' "plugins-only desired-state reconciliation"
require_source 'plugins.reconcile.data-machine' "explicit data-machine operation name"
require_source 'plugins.reconcile.data-machine-code' "explicit data-machine-code operation name"
require_source 'plugins.reconcile.wp-codebox' "explicit wp-codebox operation name"
require_file_source "$ROOT_DIR/lib/detect.sh" 'Plugin-only scope: installed Data Machine plugins only; runtime, bridge, workspace, and service synchronization disabled' "plugin-only scope evidence"
require_source '--plugins-only cannot be combined with service, runtime, migration, or other --*-only operations' "plugin-only exclusivity guard"
require_source 'if _run_filter_active systemd; then' "systems-capability mutation guard"
require_source '_print_plugins_only_verify_block' "plugins-only summary"

plugins_phase="$(sed -n '/^update_data_machine_plugins() {/,/^}/p' "$UPGRADE")"
case "$plugins_phase" in
  *dmc_managed_release_integration_sync*|*sync_carried_plugins*|*configure_homeboy_worktree_ownership*)
    echo "FAIL: plugins-only phase includes reconciliation state" >&2
    exit 1
    ;;
esac

data_machine_phase="$(sed -n '/^upgrade_data_machine_plugins() {/,/^}/p' "$ROOT_DIR/lib/data-machine.sh")"
case "$data_machine_phase" in
  *set_compose_agents_md_constant*)
    echo "FAIL: Data Machine plugin updates write non-plugin configuration" >&2
    exit 1
    ;;
esac

load_upgrade_function() {
  sed -n "/^$1() {/,/^}/p" "$UPGRADE"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/plugins/data-machine" \
  "$SITE_PATH/wp-content/plugins/data-machine-code" \
  "$SITE_PATH/wp-content/plugins/wp-codebox"
PLUGIN_UPDATE_EXIT_PARTIAL=75
SCRIPT_DIR="$ROOT_DIR"
source "$ROOT_DIR/lib/plugin-upgrade.sh"
source "$ROOT_DIR/lib/desired-state-reconciler.sh"

eval "$(load_upgrade_function _run_filter_active)"
eval "$(load_upgrade_function update_data_machine_plugins)"
eval "$(load_upgrade_function _reconcile_data_machine_plugin)"
eval "$(load_upgrade_function _reconcile_data_machine_code_plugin)"
eval "$(load_upgrade_function _reconcile_wp_codebox_plugin)"
eval "$(load_upgrade_function _reconcile_installed_plugins_verify)"
eval "$(load_upgrade_function reconcile_installed_plugins)"
eval "$(load_upgrade_function reconcile_provider_and_service_state)"
eval "$(load_upgrade_function update_chat_bridge_systemd)"
eval "$(load_upgrade_function update_chat_bridge_launchd)"

LOCAL_SERVICE="$TMP/com.wp.kimaki.plist"
VPS_SERVICE="$TMP/kimaki.service"
printf 'local service sentinel\n' > "$LOCAL_SERVICE"
printf 'vps service sentinel\n' > "$VPS_SERVICE"

KIMAKI_ONLY=false
PLUGINS_ONLY=true
SKILLS_ONLY=false
AGENTS_MD_ONLY=false
RECONCILE_SERVICES_ONLY=false
SKIP_PLUGINS=false
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
IS_STUDIO=false
PLATFORM=mac
CHAT_BRIDGE=kimaki
upgrade_data_machine_plugins() { printf 'data-machine\n' >> "$TMP/plugins"; }
update_wp_codebox_plugin_subtree() { printf 'codebox\n' >> "$TMP/plugins"; }
plugin_update_execute() { local slug="$1"; shift; "$@"; }
plugin_update_verify_installed_plugins() { :; }
log() { LOG="${LOG:-}$*"$'\n'; }
warn() { LOG="${LOG:-}$*"$'\n'; }
set_compose_agents_md_constant() { printf 'configuration\n' >> "$TMP/reconciliation"; }
sync_carried_plugins() { printf 'carried\n' >> "$TMP/reconciliation"; }
configure_homeboy_worktree_ownership() { printf 'homeboy\n' >> "$TMP/reconciliation"; }
bridge_has_hook() { return 0; }
bridge_update_launchd() { printf 'changed\n' >> "$LOCAL_SERVICE"; }
bridge_update_systemd() { printf 'changed\n' >> "$VPS_SERVICE"; }

update_plugin_to_latest_tag() { printf '%s\n' "$1" >> "$TMP/plugins"; }
installation_profile_normalize "$INSTALLATION_OPERATION_PLUGINS_ONLY"
update_data_machine_plugins
reconcile_provider_and_service_state
update_chat_bridge_launchd
LOCAL_MODE=false
update_chat_bridge_systemd

test "$(cat "$TMP/plugins")" = $'data-machine\ndata-machine-code\ncodebox' || {
  echo "FAIL: plugins-only did not run exactly the plugin updaters" >&2
  exit 1
}
case "$LOG" in
  *'profile=operation=plugins-only'*'components=data-machine data-machine-code wp-codebox'*'record=plugins.data-machine operation=plugins.reconcile.data-machine planned'*'record=plugins.data-machine operation=plugins.reconcile.data-machine apply=start'*'record=plugins.data-machine operation=plugins.reconcile.data-machine apply=complete'*) : ;;
  *) echo "FAIL: plugins-only did not emit planned-step evidence" >&2; exit 1 ;;
esac

# The normalized profile, not a second updater list, is plan authority.
rm -f "$TMP/plugins"
INSTALLATION_PROFILE_PLUGIN_CANDIDATES=(wp-codebox)
update_data_machine_plugins
test "$(cat "$TMP/plugins")" = 'codebox' || {
  echo "FAIL: plugins-only plan ignored the normalized component set" >&2
  exit 1
}
test ! -e "$TMP/reconciliation" || {
  echo "FAIL: plugins-only ran provider or Homeboy reconciliation" >&2
  exit 1
}
test "$(cat "$LOCAL_SERVICE")" = 'local service sentinel' || {
  echo "FAIL: plugins-only changed the local LaunchAgent" >&2
  exit 1
}
test "$(cat "$VPS_SERVICE")" = 'vps service sentinel' || {
  echo "FAIL: plugins-only changed the VPS service" >&2
  exit 1
}

echo "PASS: --plugins-only is limited to setup-installed plugins"
