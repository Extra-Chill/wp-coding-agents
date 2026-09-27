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
require_source 'PLUGINS_DIR="$(bridge_managed_plugins_dir)"' "repair resolves the persistent bridge plugin path in the parent process"
require_source 'global_plugin="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/claude-code-auth.ts"' "checks the OpenCode global plugin location"
require_source 'const claudeCodeAuthPlugin: Plugin = async (input) => {' "recognizes the legacy global plugin initializer"
require_source '"legacy global OpenCode Claude Code auth plugin"' "syncs only the recognized legacy global plugin through managed-file backup handling"
require_source 'install_source_sync_managed_file' "managed plugin sync preserves diverged plugin data"

source "$SCRIPT_DIR/lib/install-source.sh"
warn() { printf '%s\n' "$*" >&2; }
# Exercise the actual upgrade function without running the live-site phases.
source <(python3 - "$UPGRADE" <<'PY'
import sys
source = open(sys.argv[1]).read()
start = source.index('upgrade_opencode_claude_code_auth_plugin_path() {')
end = source.index('\ncheck_opencode_json_drift() {', start)
print(source[start:end])
PY
)

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
HOME="$fixture/home"
XDG_CONFIG_HOME="$fixture/config"
SITE_PATH="$fixture/site"
SCRIPT_DIR="$SCRIPT_DIR"
WITH_CLAUDE_CODE_AUTH=true
DRY_RUN=false
BLUE=''
NC=''
TIMESTAMP=regression
UPDATED_ITEMS=()
mkdir -p "$SITE_PATH" "$XDG_CONFIG_HOME/opencode/plugins"
global="$XDG_CONFIG_HOME/opencode/plugins/claude-code-auth.ts"
cat > "$global" <<'LEGACY'
// claude-code-auth.ts - OpenCode Anthropic auth via Claude Code OAuth.
const CLAUDE_CODE_VERSION = "2.1.259";
const claudeCodeAuthPlugin: Plugin = async (input) => {
  return { auth: { provider: "anthropic" } };
};
export { claudeCodeAuthPlugin };
LEGACY
upgrade_install_opencode_claude_code_auth_plugin
cmp "$global" "$SCRIPT_DIR/runtimes/opencode/plugins/claude-code-auth.ts"
grep -Fq '2.1.259' "$global.backup.regression"
cmp "$SITE_PATH/.opencode/plugins/claude-code-auth.ts" "$global"

cat > "$global" <<'UNRELATED'
// Personal Anthropic auth plugin; leave my implementation alone.
export const claudeCodeAuthPlugin = () => ({});
UNRELATED
upgrade_install_opencode_claude_code_auth_plugin
grep -Fq 'Personal Anthropic auth plugin' "$global"

DRY_RUN=true
cat > "$global" <<'LEGACY'
// claude-code-auth.ts - OpenCode Anthropic auth via Claude Code OAuth.
const claudeCodeAuthPlugin: Plugin = async (input) => {
  return {};
};
export { claudeCodeAuthPlugin };
LEGACY
upgrade_install_opencode_claude_code_auth_plugin
grep -Fq 'return {};' "$global"

echo "PASS: tests/upgrade-opencode-auth-plugin-sync.sh"
