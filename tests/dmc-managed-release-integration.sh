#!/bin/bash
# Regression coverage for the wp-coding-agents-owned DMC integration contract.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT_DIR/templates/wp-coding-agents-dmc-managed-release.php"

require_source() {
  grep -Fq -- "$1" "$TEMPLATE" || { echo "FAIL: missing $2" >&2; exit 1; }
}

require_source "datamachine_code_managed_release_channel" "managed release channel filter"
require_source "--dmc-managed-release-status" "shared updater status endpoint"
require_source "--plugins-only" "shared updater convergence command"
require_source "datamachine_code_runtime_source_doctor_config" "runtime doctor integration filter"
require_source "datamachine-code runtime release" "runtime doctor release command contract"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
SPECIAL_SCRIPT_DIR="$TMP/with & | ' special"
mkdir -p "$SITE_PATH/wp-content/mu-plugins" "$SPECIAL_SCRIPT_DIR/templates"
cp "$TEMPLATE" "$SPECIAL_SCRIPT_DIR/templates/wp-coding-agents-dmc-managed-release.php"
SCRIPT_DIR="$SPECIAL_SCRIPT_DIR"
DRY_RUN=false
UPDATED_ITEMS=()
warn() { echo "FAIL: $*" >&2; exit 1; }
service_file_normalize_perms() { :; }
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/dmc-managed-release-integration.sh"
dmc_managed_release_integration_sync
rendered_script="$TMP/with & | \\' special/upgrade.sh"
grep -Fq "$rendered_script" "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" || { echo "FAIL: special-character script path was not rendered safely" >&2; exit 1; }
php -l "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" >/dev/null || { echo "FAIL: rendered special-character path produced invalid PHP" >&2; exit 1; }

echo "dmc-managed-release-integration tests passed"
