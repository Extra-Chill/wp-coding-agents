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
    'option list') printf '0\n' ;;
    *) return 1 ;;
  esac
}
sync_carried_plugins() {
  printf 'sync\n' >> "$CARRIED_TRACE"
  mkdir -p "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code"
}

SCRIPT_DIR="$ROOT_DIR"
SITE_PATH="$TMP/site"
INSTALLATION_PROFILE_SITE_PATH="$SITE_PATH"
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=false
INSTALLATION_PROFILE_HOMEBOY_MODE=disabled
RUNTIME=claude-code
DETECTED_RUNTIMES=(claude-code)
DRY_RUN=false
CARRIED_TRACE="$TMP/carried-sync"
HOMEBOY_TRACE="$TMP/homeboy-sync"
BLUE=""; NC=""
mkdir -p "$SITE_PATH/wp-content/plugins/data-machine-code"
printf 'copied\n' > "$SITE_PATH/wp-content/plugins/data-machine-code/HOMEBOY_DEPLOYED"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
printf 'stale\n' > "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php"

INSTALLATION_PROFILE_OPERATION=setup
integration_adapters_detect
setup_records="${INTEGRATION_ADAPTER_RECORDS[*]}"
INSTALLATION_PROFILE_OPERATION=upgrade
integration_adapters_detect
[ "$setup_records" = "${INTEGRATION_ADAPTER_RECORDS[*]}" ] || fail "setup and upgrade derived different records"
case "$setup_records" in
  *"integrations.dmc-managed-release-cleanup"*"integrations.dmc-copied-release"*"integrations.carried-plugin.ai-provider-for-claude-code"*) ;;
  *) fail "expected managed-release, copied-DMC, and carried-plugin records" ;;
esac

reconciler_plan_reset
integration_adapters_plan
integration_adapters_apply
[ ! -e "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" ] || fail "managed-release cleanup was not applied"
[ -f "$SITE_PATH/wp-content/plugins/data-machine-code/HOMEBOY_DEPLOYED" ] || fail "copied DMC was changed"
[ -d "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code" ] || fail "carried provider was not applied"
[ "$(grep -c '^homeboy$' "$HOMEBOY_TRACE")" -eq 1 ] || fail "disabled Homeboy cleanup was not applied"

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
[ "${#INTEGRATION_ADAPTER_RECORDS[@]}" -eq 2 ] || fail "absent Homeboy cleanup was not planned"
[ "${INTEGRATION_ADAPTER_RECORDS[1]}" = "integrations.homeboy" ] || fail "Homeboy cleanup record missing"

# Verification reads Homeboy's command-result envelope and rejects a nested
# legacy DMC provider rather than treating the envelope root as config.
printf '#!/bin/sh\nexit 0\n' > "$TMP/homeboy"
chmod +x "$TMP/homeboy"
PATH="$TMP:/usr/bin:/bin"
homeboy_wordpress_extension_ready() { return 1; }
homeboy_run() {
  printf '%s\n' '{"schema":"homeboy/command-result/v3","data":{"config":{"worktree_providers":{"dmc":{}}}}}'
}
if _integration_adapter_verify_homeboy; then fail "nested DMC provider passed Homeboy verification"; fi
homeboy_run() {
  printf '%s\n' '{"schema":"homeboy/command-result/v3","data":{"config":{"worktree_providers":{}}}}'
}
_integration_adapter_verify_homeboy || fail "clean Homeboy envelope failed verification"

# Disabled cleanup is complete only when WordPress can prove the stale option
# is absent; transport failure must remain a convergence failure.
INSTALLATION_PROFILE_HOMEBOY_MODE=disabled
wp_cmd() { return 1; }
if _integration_adapter_verify_homeboy; then fail "unverified Homeboy availability cleanup passed"; fi

EXTERNAL_SITE="$TMP/external"
INSTALLATION_PROFILE_SITE_PATH="$EXTERNAL_SITE"
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=true
integration_adapters_detect
[ "${#INTEGRATION_ADAPTER_RECORDS[@]}" -eq 0 ] || fail "external WordPress planned local integrations"

echo "PASS: integration adapters preserve profile-derived optional policy"
