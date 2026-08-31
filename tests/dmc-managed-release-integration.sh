#!/bin/bash
# wp-coding-agents no longer owns a DMC managed-release or runtime-doctor channel.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ ! -e "$ROOT_DIR/lib/dmc-managed-release.sh" ] || fail "copied-release updater still present"
[ ! -e "$ROOT_DIR/lib/dmc-managed-release-integration.sh" ] || fail "managed-release integration still present"
[ ! -e "$ROOT_DIR/templates/wp-coding-agents-dmc-managed-release.php" ] || fail "managed-release template still present"

if grep -Fq 'dmc_managed_release' "$ROOT_DIR/upgrade.sh"; then
  fail "upgrade.sh still calls managed-release helpers"
fi
if grep -Fq -- '--dmc-managed-release-status' "$ROOT_DIR/upgrade.sh"; then
  fail "upgrade.sh still exposes managed-release status"
fi
if grep -Fq 'update_data_machine_code_copied_release' "$ROOT_DIR/lib/data-machine.sh"; then
  fail "plugin upgrades still convert copied DMC"
fi
grep -Fq 'rm -f "$file"' "$ROOT_DIR/lib/integration-adapters.sh" || fail "integration adapter does not remove the stale managed-release mu-plugin"

channel_hits="$(grep -R --include='*.php' --include='*.sh' -l 'datamachine_code_managed_release_channel' "$ROOT_DIR" || true)"
case "$channel_hits" in
  */tests/*|'' ) : ;;
  *) fail "managed-release channel filter still shipped: $channel_hits" ;;
esac
doctor_hits="$(grep -R --include='*.php' --include='*.sh' -l 'datamachine_code_runtime_source_doctor_config' "$ROOT_DIR" || true)"
case "$doctor_hits" in
  */tests/*|'' ) : ;;
  *) fail "runtime-doctor ownership filter still shipped: $doctor_hits" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH/wp-content/mu-plugins"
printf 'stale-channel\n' > "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php"

source "$ROOT_DIR/lib/desired-state-reconciler.sh"
source "$ROOT_DIR/lib/integration-adapters.sh"
log() { :; }
warn() { :; }
error() { fail "$1"; }
setup_homeboy_project() { :; }
configure_homeboy_worktree_ownership() { :; }
configure_homeboy_wordpress_extension() { :; }
homeboy_required() { return 1; }
wp_cmd() {
  case "$1 $2" in
    'option list') printf '0\n' ;;
    *) return 1 ;;
  esac
}
DRY_RUN=false
INSTALLATION_PROFILE_SITE_PATH="$SITE_PATH"
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=false
INSTALLATION_PROFILE_HOMEBOY_MODE=disabled
reconciler_plan_reset
integration_adapters_plan
integration_adapters_apply
[ ! -e "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" ] || fail "stale managed-release mu-plugin was retained"

echo "dmc-managed-release-integration tests passed"
