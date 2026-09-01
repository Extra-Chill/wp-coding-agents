#!/bin/bash
# Regression coverage for stale generated runtime-registry cleanup.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
MU_FILE="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
printf '%s\n' '<?php add_filter("datamachine_code_worktree_runtime_signatures", "__return_empty_array");' > "$MU_FILE"

source "$SCRIPT_DIR/lib/runtime-signature.sh"
warn() { printf '%s\n' "$*"; }
DRY_RUN=true
BLUE=""
NC=""
runtime_signature_cleanup_retired_mu_plugin > "$TMP/dry-run"
[ -e "$MU_FILE" ] || { echo "FAIL: dry run removed runtime registry" >&2; exit 1; }
grep -q 'Would remove installer-owned retired runtime registry' "$TMP/dry-run"

DRY_RUN=false
UPDATED_ITEMS=()
runtime_signature_cleanup_retired_mu_plugin
[ ! -e "$MU_FILE" ] || { echo "FAIL: runtime registry was retained" >&2; exit 1; }
[ "${UPDATED_ITEMS[*]}" = "removed retired runtime registry" ] || { echo "FAIL: cleanup was not reported" >&2; exit 1; }
printf '%s\n' '<?php // operator-owned content' > "$MU_FILE"
if runtime_signature_cleanup_retired_mu_plugin; then echo "FAIL: cleanup removed unknown runtime registry" >&2; exit 1; fi
[ -e "$MU_FILE" ] || { echo "FAIL: unknown runtime registry was removed" >&2; exit 1; }
DRY_RUN=true
if runtime_signature_cleanup_retired_mu_plugin > "$TMP/unknown-dry-run"; then echo "FAIL: dry-run cleanup accepted unknown runtime registry" >&2; exit 1; fi
grep -q 'Would preserve unknown runtime registry' "$TMP/unknown-dry-run"
echo "OK: runtime registry cleanup is idempotent and no-op after removal"
