#!/bin/bash
# tests/carried-plugins.sh — carried plugins follow the installation profile.
#
# A desired carried plugin is synced and activated; a managed copy (marker file)
# of one the profile no longer wants is deactivated and removed, failing closed
# when WordPress cannot deactivate it. Uses fixture plugins so the contract does
# not depend on which plugins wp-coding-agents currently carries.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/carried-plugins.sh"

SCRIPT_DIR="$TMP/source"
SITE_PATH="$TMP/site"
mkdir -p "$SCRIPT_DIR/carried-plugins/fixture-wanted" "$SCRIPT_DIR/carried-plugins/fixture-retired" "$SITE_PATH/wp-content/plugins"
printf '<?php\n' > "$SCRIPT_DIR/carried-plugins/fixture-wanted/fixture-wanted.php"
printf '<?php\n' > "$SCRIPT_DIR/carried-plugins/fixture-retired/fixture-retired.php"

DRY_RUN=true
IS_STUDIO=false
MULTISITE=false
WP_CMD=wp
WP_ROOT_FLAG=
INSTALLATION_PROFILE_CARRIED_PLUGINS=(fixture-wanted)

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# An unmanaged directory with an undesired slug is never touched.
mkdir -p "$SITE_PATH/wp-content/plugins/fixture-retired"
output="$(sync_carried_plugins)"
case "$output" in
  *"Removing undesired carried plugin: fixture-retired"*) fail "unmanaged plugin directory was scheduled for removal" ;;
  *"Syncing carried plugin: fixture-wanted"*"plugin activate fixture-wanted"*) ;;
  *) fail "desired carried plugin was not synced: $output" ;;
esac

printf 'wp-coding-agents/carried-plugin/v1\n' > "$SITE_PATH/wp-content/plugins/fixture-retired/.wp-coding-agents-carried"
output="$(sync_carried_plugins)"
case "$output" in
  *"Removing undesired carried plugin: fixture-retired"*"plugin deactivate fixture-retired"*) ;;
  *) fail "undesired managed plugin was not scheduled for removal: $output" ;;
esac

# Removal fails closed when WordPress cannot deactivate the managed plugin.
DRY_RUN=false
wp_cmd() { return 1; }
activate_plugin() { :; }
fix_ownership() { :; }
if sync_carried_plugins >/dev/null 2>&1; then
  fail "failed plugin deactivation did not fail reconciliation"
fi
[ -f "$SITE_PATH/wp-content/plugins/fixture-retired/.wp-coding-agents-carried" ] || \
  fail "failed deactivation removed the managed plugin files"

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
[ ! -e "$SITE_PATH/wp-content/plugins/fixture-retired" ] || fail "multisite reconciliation retained an undesired managed plugin"
[ -f "$SITE_PATH/wp-content/plugins/fixture-wanted/fixture-wanted.php" ] || fail "desired carried plugin was not copied"
for expected in \
  'plugin deactivate fixture-retired --network' \
  'plugin deactivate fixture-retired --url=https://one.example/' \
  'plugin deactivate fixture-retired --url=https://two.example/'; do
  grep -qF "$expected" "$WP_TRACE" || fail "missing multisite deactivation: $expected"
done

echo "PASS: tests/carried-plugins.sh"
