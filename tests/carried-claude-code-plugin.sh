#!/bin/bash
# tests/carried-claude-code-plugin.sh — Claude Code runtime syncs its carried provider plugin.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/plugins"

export SCRIPT_DIR
export SITE_PATH
export DRY_RUN=true
export IS_STUDIO=false
export MULTISITE=false
export WP_CMD=wp
export WP_ROOT_FLAG=

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/carried-plugins.sh"

DETECTED_RUNTIMES=(claude-code)
RUNTIME=claude-code

output="$(sync_carried_plugins)"

case "$output" in
  *"Syncing carried plugin: ai-provider-for-claude-code"*"wp plugin activate ai-provider-for-claude-code"*) ;;
  *)
    printf 'Expected Claude Code carried plugin sync, got:\n%s\n' "$output" >&2
    exit 1
    ;;
esac

DETECTED_RUNTIMES=(opencode)
RUNTIME=opencode

output="$(sync_carried_plugins)"
if [ -n "$output" ]; then
  printf 'Expected no carried plugin sync for opencode, got:\n%s\n' "$output" >&2
  exit 1
fi

echo "PASS: tests/carried-claude-code-plugin.sh"
