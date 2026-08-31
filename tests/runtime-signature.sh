#!/bin/bash
# Regression coverage for stale generated runtime-registry cleanup.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
MU_FILE="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
printf '%s\n' '<?php // retired DMC registry' > "$MU_FILE"

source "$SCRIPT_DIR/lib/runtime-signature.sh"
DRY_RUN=true
BLUE=""
NC=""
runtime_signature_cleanup_retired_mu_plugin > "$TMP/dry-run"
[ -e "$MU_FILE" ] || { echo "FAIL: dry run removed runtime registry" >&2; exit 1; }
grep -q 'rm -f' "$TMP/dry-run"

DRY_RUN=false
UPDATED_ITEMS=()
runtime_signature_cleanup_retired_mu_plugin
[ ! -e "$MU_FILE" ] || { echo "FAIL: runtime registry was retained" >&2; exit 1; }
[ "${UPDATED_ITEMS[*]}" = "removed retired runtime registry" ] || { echo "FAIL: cleanup was not reported" >&2; exit 1; }
echo "OK: runtime registry cleanup is idempotent and no-op after removal"
