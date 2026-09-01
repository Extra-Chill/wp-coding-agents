#!/bin/bash
# Setup and upgrade use the same persisted intent to derive integration records.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT_DIR/lib/desired-state-reconciler.sh"
source "$ROOT_DIR/lib/carried-plugins.sh"
source "$ROOT_DIR/lib/integration-adapters.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
log() { :; }
warn() { :; }
error() { fail "$1"; }
setup_homeboy_project() { :; }
configure_homeboy_worktree_ownership() { :; }
configure_homeboy_wordpress_extension() { printf 'homeboy\n' >> "$HOMEBOY_TRACE"; }
homeboy_required() { return 1; }
wp_cmd() {
  case "$1 $2" in
    'eval $missing = new stdClass(); exit( $missing === get_option( "datamachine_code_homeboy_available", $missing ) ? 0 : 1 );')
      printf 'Deprecated: diagnostic text on stdout\n'
      [ ! -e "$RETIRED_HOMEBOY_OPTION_STATE" ]
      ;;
    'option delete') rm -f "$RETIRED_HOMEBOY_OPTION_STATE" ;;
    'plugin is-active') return 0 ;;
    'eval exit(false !== has_filter("intelligence_host_has_shell", "WpCodingAgents\\Integration\\provide_intelligence_shell_capability") && false !== has_filter("intelligence_host_has_writable_content_directory", "WpCodingAgents\\Integration\\provide_intelligence_writable_content_capability") ? 0 : 1);') [ "${HOST_CAPABILITIES_AVAILABLE:-true}" = true ] ;;
    *) return 1 ;;
  esac
}
sync_carried_plugins() {
  printf 'sync\n' >> "$CARRIED_TRACE"
  mkdir -p "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code"
  mkdir -p "$SITE_PATH/wp-content/plugins/wp-coding-agents-integration"
}

SCRIPT_DIR="$ROOT_DIR"
SITE_PATH="$TMP/site"
INSTALLATION_PROFILE_SITE_PATH="$SITE_PATH"
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=false
INSTALLATION_PROFILE_HOMEBOY_MODE=disabled
RUNTIME=claude-code
DETECTED_RUNTIMES=(claude-code)
INSTALLATION_PROFILE_CARRIED_PLUGINS=(wp-coding-agents-integration ai-provider-for-claude-code)
DRY_RUN=false
RETIRED_HOMEBOY_OPTION_STATE="$TMP/retired-homeboy-option"
touch "$RETIRED_HOMEBOY_OPTION_STATE"
CARRIED_TRACE="$TMP/carried-sync"
HOMEBOY_TRACE="$TMP/homeboy-sync"
BLUE=""; NC=""
mkdir -p "$SITE_PATH/wp-content/plugins/data-machine-code"
printf 'copied\n' > "$SITE_PATH/wp-content/plugins/data-machine-code/HOMEBOY_DEPLOYED"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
printf '%s\n' '<?php add_filter("datamachine_code_managed_release_channel", "__return_false");' > "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php"

INSTALLATION_PROFILE_OPERATION=setup
integration_adapters_detect
setup_records="${INTEGRATION_ADAPTER_RECORDS[*]}"
INSTALLATION_PROFILE_OPERATION=upgrade
integration_adapters_detect
[ "$setup_records" = "${INTEGRATION_ADAPTER_RECORDS[*]}" ] || fail "setup and upgrade derived different records"
case "$setup_records" in
  *"integrations.dmc-managed-release-cleanup"*"integrations.retired-homeboy-option-cleanup"*"integrations.dmc-copied-release"*"integrations.carried-plugin.ai-provider-for-claude-code"*"integrations.carried-plugin.wp-coding-agents-integration"*) ;;
  *) fail "expected stale-state, copied-DMC, and carried-plugin records" ;;
esac

reconciler_plan_reset
integration_adapters_plan
integration_adapters_apply
[ ! -e "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" ] || fail "managed-release cleanup was not applied"
[ ! -e "$RETIRED_HOMEBOY_OPTION_STATE" ] || fail "retired Homeboy option was not removed"
[ -f "$SITE_PATH/wp-content/plugins/data-machine-code/HOMEBOY_DEPLOYED" ] || fail "copied DMC was changed"
[ -d "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code" ] || fail "carried provider was not applied"
[ -d "$SITE_PATH/wp-content/plugins/wp-coding-agents-integration" ] || fail "WordPress integration package was not applied"
[ "$(grep -c '^homeboy$' "$HOMEBOY_TRACE")" -eq 1 ] || fail "disabled Homeboy cleanup was not applied"
HOST_CAPABILITIES_AVAILABLE=false
if _integration_adapter_verify_carried_plugins; then fail "missing integration hook adapters passed verification"; fi
HOST_CAPABILITIES_AVAILABLE=true

# Multiple eligible carried sources are one aggregate desired-state effect.
mkdir -p "$TMP/carried-plugins/one" "$TMP/carried-plugins/two"
mkdir -p "$SITE_PATH/wp-content/plugins/one" "$SITE_PATH/wp-content/plugins/two"
SCRIPT_DIR="$TMP"
carried_plugin_should_install() { return 0; }
integration_adapters_detect
reconciler_plan_reset
integration_adapters_plan
[ "$(printf '%s\n' "${RECONCILER_PLAN_RECORDS[@]}" | grep -c '^integrations.carried-plugins$')" -eq 1 ] || fail "carried plugins were planned more than once"
integration_adapters_apply
[ "$(grep -c '^sync$' "$CARRIED_TRACE")" -eq 2 ] || fail "carried plugins did not execute as one aggregate sync"
SCRIPT_DIR="$ROOT_DIR"

# Auto Homeboy absence retains one adapter record to clean stale WordPress state.
rm -rf "$SITE_PATH/wp-content/plugins/data-machine-code"
INSTALLATION_PROFILE_HOMEBOY_MODE=auto
# Keep core utilities available while removing the test-local fake Homeboy path.
PATH="/usr/bin:/bin"
integration_adapters_detect
case "${INTEGRATION_ADAPTER_RECORDS[*]}" in
  *"integrations.homeboy") ;;
  *) fail "Homeboy cleanup record missing" ;;
esac

# Verification reads Homeboy's command-result envelope and rejects a nested
# legacy DMC provider rather than treating the envelope root as config.
printf '#!/bin/sh\nexit 0\n' > "$TMP/homeboy"
chmod +x "$TMP/homeboy"
PATH="$TMP:/usr/bin:/bin"
homeboy_wordpress_extension_ready() { return 1; }
homeboy_run() {
  printf '%s\n' '{"schema":"homeboy/command-result/v3","data":{"config":{"worktree_providers":{"dmc":{}},"settings":{"worktree_provider_lifecycle":{}}}}}'
}
if _integration_adapter_verify_homeboy; then fail "nested DMC provider passed Homeboy verification"; fi
homeboy_run() {
  printf '%s\n' '{"schema":"homeboy/command-result/v3","data":{"config":{"worktree_providers":{},"settings":{"worktree_provider_lifecycle":{"dmc":{}}}}}}'
}
if _integration_adapter_verify_homeboy; then fail "nested DMC lifecycle passed Homeboy verification"; fi
homeboy_run() {
  printf '%s\n' '{"schema":"homeboy/command-result/v3","data":{"config":{"worktree_providers":{},"settings":{"worktree_provider_lifecycle":{}}}}}'
}
_integration_adapter_verify_homeboy || fail "clean Homeboy envelope failed verification"

printf 'operator-owned managed release\n' > "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php"
if _integration_adapter_cleanup_managed_release; then fail "unknown managed release cleanup reported success"; fi
[ -e "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" ] || fail "unknown managed release was removed"

# Retired-option cleanup must fail closed when WordPress cannot confirm absence.
wp_cmd() { return 1; }
if _integration_adapter_verify_retired_homeboy_option; then fail "unverified retired Homeboy option cleanup passed"; fi

EXTERNAL_SITE="$TMP/external"
INSTALLATION_PROFILE_SITE_PATH="$EXTERNAL_SITE"
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=true
integration_adapters_detect
[ "${#INTEGRATION_ADAPTER_RECORDS[@]}" -eq 0 ] || fail "external WordPress planned local integrations"

echo "PASS: integration adapters preserve profile-derived optional policy"
