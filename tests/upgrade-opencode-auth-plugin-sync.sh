#!/bin/bash
# tests/upgrade-opencode-auth-plugin-sync.sh - upgrade syncs OpenCode auth plugin on mixed-runtime installs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$SCRIPT_DIR/upgrade.sh"

require_source() {
  local pattern="$1"
  local description="$2"
  if ! grep -Fq "$pattern" "$UPGRADE"; then
    echo "FAIL: missing $description" >&2
    echo "pattern: $pattern" >&2
    exit 1
  fi
}

require_source "upgrade_opencode_claude_code_auth_plugin_path()" "upgrade-owned OpenCode auth plugin path helper"
require_source "upgrade_install_opencode_claude_code_auth_plugin()" "upgrade-owned OpenCode auth plugin installer"
require_source 'source_path="$SCRIPT_DIR/runtimes/opencode/plugins/claude-code-auth.ts"' "copy from released OpenCode auth plugin source"
require_source "upgrade_install_opencode_claude_code_auth_plugin" "opencode.json drift phase installs auth plugin"
require_source 'CLAUDE_CODE_AUTH_PLUGIN="$(upgrade_opencode_claude_code_auth_plugin_path)"' "repair helper receives site-local auth plugin path"

echo "PASS: tests/upgrade-opencode-auth-plugin-sync.sh"
