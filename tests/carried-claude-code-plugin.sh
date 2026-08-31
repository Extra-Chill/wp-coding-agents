#!/bin/bash
# tests/carried-claude-code-plugin.sh — Claude Code runtime syncs its carried provider plugin.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
PROVIDER_DIR="$SCRIPT_DIR/carried-plugins/ai-provider-for-claude-code"
mkdir -p "$SITE_PATH/wp-content/plugins"

for required_file in \
  "$PROVIDER_DIR/src/Provider/ClaudeCodeProvider.php" \
  "$PROVIDER_DIR/src/Provider/ClaudeCodeOAuthClient.php" \
  "$PROVIDER_DIR/src/Provider/ClaudeCodeRequestAuthentication.php" \
  "$PROVIDER_DIR/src/Provider/ClaudeCodeTokenStore.php"; do
  if [ ! -f "$required_file" ]; then
    printf 'Expected Claude Code provider file to exist: %s\n' "$required_file" >&2
    exit 1
  fi
done

if [ -e "$PROVIDER_DIR/src/Runtime/ClaudeCodeProcess.php" ]; then
  printf 'Claude Code provider must use OAuth/API auth, not the local CLI process runtime.\n' >&2
  exit 1
fi

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
INSTALLATION_PROFILE_CARRIED_PLUGINS=(wp-coding-agents-integration ai-provider-for-claude-code)

output="$(sync_carried_plugins)"

case "$output" in
  *"Syncing carried plugin: ai-provider-for-claude-code"*"wp plugin activate ai-provider-for-claude-code"*"Syncing carried plugin: wp-coding-agents-integration"*"wp plugin activate wp-coding-agents-integration"*) ;;
  *)
    printf 'Expected Claude Code carried plugin sync, got:\n%s\n' "$output" >&2
    exit 1
    ;;
esac

DETECTED_RUNTIMES=(opencode)
RUNTIME=opencode
INSTALLATION_PROFILE_CARRIED_PLUGINS=(wp-coding-agents-integration)
mkdir -p "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code"
printf 'wp-coding-agents/carried-plugin/v1\n' > "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code/.wp-coding-agents-carried"

output="$(sync_carried_plugins)"
case "$output" in
  *"Removing undesired carried plugin: ai-provider-for-claude-code"*"plugin deactivate ai-provider-for-claude-code"*"Syncing carried plugin: wp-coding-agents-integration"*) ;;
  *) printf 'Expected the WordPress integration package for opencode, got:\n%s\n' "$output" >&2; exit 1 ;;
esac

# Removal fails closed when WordPress cannot deactivate the managed plugin.
DRY_RUN=false
MULTISITE=false
wp_cmd() { return 1; }
activate_plugin() { :; }
fix_ownership() { :; }
if sync_carried_plugins >/dev/null 2>&1; then
  printf 'Expected failed plugin deactivation to fail reconciliation.\n' >&2
  exit 1
fi
if [ ! -f "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code/.wp-coding-agents-carried" ]; then
  printf 'Failed deactivation removed the managed plugin files.\n' >&2
  exit 1
fi

# Multisite removal deactivates the plugin network-wide and on every site.
MULTISITE=true
WP_TRACE="$TMP/wp-trace"
wp_cmd() {
  printf '%s\n' "$*" >> "$WP_TRACE"
  if [ "$1 $2 $3" = "site list --field=url" ]; then
    printf '%s\n' 'https://one.example/' 'https://two.example/'
  fi
}
sync_carried_plugins >/dev/null
if [ -e "$SITE_PATH/wp-content/plugins/ai-provider-for-claude-code" ]; then
  printf 'Multisite reconciliation retained an undesired managed plugin.\n' >&2
  exit 1
fi
for expected in \
  'plugin deactivate ai-provider-for-claude-code --network' \
  'plugin deactivate ai-provider-for-claude-code --url=https://one.example/' \
  'plugin deactivate ai-provider-for-claude-code --url=https://two.example/'; do
  if ! grep -qF "$expected" "$WP_TRACE"; then
    printf 'Missing multisite deactivation: %s\n' "$expected" >&2
    exit 1
  fi
done

echo "PASS: tests/carried-claude-code-plugin.sh"
