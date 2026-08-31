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
sync_carried_plugins() {
  CARRIED_SYNCED=true
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
[ "${CARRIED_SYNCED:-false}" = true ] || fail "carried provider was not applied"

# Auto Homeboy absence and a DMC-free site create no optional integration work.
rm -rf "$SITE_PATH/wp-content/plugins/data-machine-code"
INSTALLATION_PROFILE_HOMEBOY_MODE=auto
# Keep core utilities available while removing the test-local fake Homeboy path.
PATH="/usr/bin:/bin"
integration_adapters_detect
[ "${#INTEGRATION_ADAPTER_RECORDS[@]}" -eq 1 ] || fail "optional Homeboy absence was not a no-op"
[ "${INTEGRATION_ADAPTER_RECORDS[0]}" = "integrations.carried-plugin.ai-provider-for-claude-code" ] || fail "unexpected optional record"

EXTERNAL_SITE="$TMP/external"
INSTALLATION_PROFILE_SITE_PATH="$EXTERNAL_SITE"
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=true
integration_adapters_detect
[ "${#INTEGRATION_ADAPTER_RECORDS[@]}" -eq 0 ] || fail "external WordPress planned local integrations"

echo "PASS: integration adapters preserve profile-derived optional policy"
