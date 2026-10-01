#!/bin/bash
# tests/wp-config-permissions.sh — Regression coverage for issue #302 in
# lib/wordpress.sh.
#
# Phase 6 grants the service user write access to the site with a recursive
# `chmod -R g+w "$SITE_PATH"`, so it can edit themes and plugins. That grant
# also sweeps in wp-config.php, which holds the database credentials, salts,
# and auth keys. The result observed on two provisioned hosts:
#
#   -rw-rw-r--  <service-user>:www-data  wp-config.php
#
# World-readable, so any local account can read the database credentials, and
# group-writable by a service user that is a member of www-data, so the coding
# agent can rewrite the site's database connection. The agent gains nothing
# from either.
#
# harden_wp_config_permissions must restore 0640 owned by www-data after the
# site-wide grant. Asserts:
#   1. A world-readable, group-writable config is tightened to 0640
#   2. It is applied unconditionally, so re-provisioning corrects a mode an
#      earlier install left loosened (not only fresh sites)
#   3. An already-correct config is left at 0640
#   4. A missing config is not an error (site not yet installed)
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source lib/common.sh

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Stub the provisioning surface harden_wp_config_permissions depends on, so
# the function can be exercised without running a real install. chown is
# recorded rather than performed: the test does not run as root and cannot
# change file ownership.
CHOWN_LOG="$TMP/chown.log"
: > "$CHOWN_LOG"

DRY_RUN=false
run_cmd() {
  if [ "${1:-}" = "chown" ] || { [ "${1:-}" = "chmod" ] && [ "$DRY_RUN" = true ]; }; then
    printf '%s\n' "$*" >> "$CHOWN_LOG"
    return 0
  fi
  "$@"
}

# shellcheck disable=SC1091
# Lives in lib/wordpress.sh: upgrade.sh does not source infrastructure.sh, and
# the service-identity migration needs this during an upgrade.
eval "$(sed -n '/^harden_wp_config_permissions() {/,/^}/p' lib/wordpress.sh)"

# The real setup and ordinary-upgrade entry points must converge using the
# resolved writable policy. Keep this scoped to the config hardener; neither
# path may substitute the broad site permissions repair.
setup_call=$(grep -n 'harden_wp_config_permissions "\$SITE_PATH"' lib/infrastructure.sh)
upgrade_resolve=$(grep -n '^source_policy_resolve_writable_paths$' upgrade.sh | cut -d: -f1)
upgrade_call=$(grep -n 'harden_wp_config_permissions "\$SITE_PATH"' upgrade.sh | cut -d: -f1)
[ -n "$setup_call" ] || fail "setup must call the config hardener"
[ -n "$upgrade_call" ] && [ "$upgrade_call" -gt "$upgrade_resolve" ] \
  || fail "ordinary upgrade must harden after resolving writable policy"

mode_of() {
  file_mode "$1"
}

# 1. The state provisioning actually leaves behind: world-readable and
#    group-writable.
site="$TMP/site"
mkdir -p "$site"
printf '<?php // credentials\n' > "$site/wp-config.php"
chmod 664 "$site/wp-config.php"

harden_wp_config_permissions "$site"

got=$(mode_of "$site/wp-config.php")
[ "$got" = "640" ] || fail "expected 0640 after hardening, got 0$got"
grep -q 'chown www-data:www-data' "$CHOWN_LOG" \
  || fail "expected ownership to be set to www-data"

# 2. Re-running provisioning on a host an earlier install left loose must
#    correct it. Without this, every already-provisioned host stays exposed.
chmod 664 "$site/wp-config.php"
harden_wp_config_permissions "$site"
got=$(mode_of "$site/wp-config.php")
[ "$got" = "640" ] || fail "re-provisioning must correct a loosened mode, got 0$got"

# 3. An already-correct config stays correct.
harden_wp_config_permissions "$site"
got=$(mode_of "$site/wp-config.php")
[ "$got" = "640" ] || fail "expected 0640 to be preserved, got 0$got"

# Explicit opt-in in workspace or owned mode uses group write only, with no
# world bits. Repeating application converges on the same exact mode.
OWNED_WRITABLE=wp-config.php
chmod 666 "$site/wp-config.php"
harden_wp_config_permissions "$site"
got=$(mode_of "$site/wp-config.php")
[ "$got" = "660" ] || fail "opt-in must set exactly 0660, got 0$got"
harden_wp_config_permissions "$site"
[ "$(mode_of "$site/wp-config.php")" = "660" ] || fail "repeat opt-in must remain 0660"
OWNED_WRITABLE=""
harden_wp_config_permissions "$site"
[ "$(mode_of "$site/wp-config.php")" = "640" ] || fail "opt-out must restore 0640"

# 4. A site path with no wp-config.php yet must not fail the phase.
empty="$TMP/empty"
mkdir -p "$empty"
harden_wp_config_permissions "$empty" \
  || fail "a missing wp-config.php must not fail provisioning"

# Dry-run routes chmod/chown through run_cmd and must not mutate the config.
chmod 666 "$site/wp-config.php"
before=$(mode_of "$site/wp-config.php")
DRY_RUN=true
OWNED_WRITABLE=""
harden_wp_config_permissions "$site"
DRY_RUN=false
[ "$(mode_of "$site/wp-config.php")" = "$before" ] \
  || fail "dry-run must not mutate wp-config.php"

# Persist and re-read opt-in and opt-out; a stale legacy value must not
# re-enable an explicit empty declaration.
source lib/source-policy.sh
SITE_PATH="$site"
SOURCE_MODE=workspace
options="$TMP/options"
mkdir -p "$options"
printf 'wp-config.php' > "$options/$SOURCE_POLICY_LEGACY_WRITABLE_OPTION"
_source_policy_option_read() {
  [ -f "$options/$1" ] && { printf '%s' "$(<"$options/$1")"; return 0; }
  return 0
}
wp_cmd() {
  [ "$1" = option ] && [ "$2" = update ] || return 1
  local key="$3" value
  value="$(cat)"
  printf '%s' "$value" > "$options/$key"
}
OWNED_WRITABLE=wp-config.php
OWNED_WRITABLE_EXPLICIT=true
source_policy_record_writable_paths
OWNED_WRITABLE_EXPLICIT=false
OWNED_WRITABLE=""
source_policy_resolve_writable_paths
[ "$OWNED_WRITABLE" = wp-config.php ] || fail "re-read must retain explicit opt-in"
OWNED_WRITABLE_EXPLICIT=true
OWNED_WRITABLE=""
source_policy_record_writable_paths
source_policy_resolve_writable_paths
[ -z "$OWNED_WRITABLE" ] || fail "re-read must retain explicit opt-out over legacy value"

# 5. World read is the specific bit that matters for a credentials file.
chmod 644 "$site/wp-config.php"
harden_wp_config_permissions "$site"
if [ $(( $(file_mode "$site/wp-config.php") % 10 & 4 )) -ne 0 ]; then
  fail "world permissions must be cleared on the credentials file"
fi

echo "wp-config permissions tests passed"
