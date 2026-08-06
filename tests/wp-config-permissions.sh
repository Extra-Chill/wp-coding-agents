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
  if [ "${1:-}" = "chown" ]; then
    printf '%s\n' "$*" >> "$CHOWN_LOG"
    return 0
  fi
  "$@"
}

# shellcheck disable=SC1091
# Lives in lib/wordpress.sh: upgrade.sh does not source infrastructure.sh, and
# the service-identity migration needs this during an upgrade.
eval "$(sed -n '/^harden_wp_config_permissions() {/,/^}/p' lib/wordpress.sh)"

mode_of() {
  stat -c '%a' "$1"
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

# 4. A site path with no wp-config.php yet must not fail the phase.
empty="$TMP/empty"
mkdir -p "$empty"
harden_wp_config_permissions "$empty" \
  || fail "a missing wp-config.php must not fail provisioning"

# 5. World read is the specific bit that matters for a credentials file.
chmod 644 "$site/wp-config.php"
harden_wp_config_permissions "$site"
if [ -r "$site/wp-config.php" ] && [ "$(stat -c '%A' "$site/wp-config.php" | cut -c8-10)" != "---" ]; then
  fail "world permissions must be cleared on the credentials file"
fi

echo "wp-config permissions tests passed"
