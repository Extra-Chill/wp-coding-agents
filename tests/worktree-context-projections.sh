#!/bin/bash
# The runtime registry and projections were DMC-only contracts.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
printf '%s\n' '<?php add_filter("datamachine_code_worktree_runtime_signatures", "__return_empty_array");' > "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"

source "$SCRIPT_DIR/lib/runtime-signature.sh"
DRY_RUN=false
UPDATED_ITEMS=()
runtime_signature_cleanup_retired_mu_plugin

[ ! -e "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php" ] || { echo "FAIL: retired runtime registry remains" >&2; exit 1; }
echo "OK: retired DMC runtime registry is removed without unsupported Homeboy hooks"
