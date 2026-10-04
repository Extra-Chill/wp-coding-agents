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
upgrade_assert=$(grep -n '^source_policy_assert_runtime_supports_mode$' upgrade.sh | cut -d: -f1)
upgrade_adopt=$(grep -n '^adopt_service_identity_from_units$' upgrade.sh | cut -d: -f1)
upgrade_call=$(grep -n '^upgrade_harden_wp_config_permissions$' upgrade.sh | cut -d: -f1)
[ -n "$setup_call" ] || fail "setup must call the config hardener"
[ -n "$upgrade_call" ] && [ "$upgrade_call" -gt "$upgrade_assert" ] && [ "$upgrade_call" -gt "$upgrade_adopt" ] \
  || fail "ordinary upgrade must harden after source validation and service identity adoption"

mode_of() {
  file_mode "$1"
}

# 1. The state provisioning actually leaves behind: world-readable and
#    group-writable.
site="$TMP/site"
mkdir -p "$site"
printf '<?php // credentials\n' > "$site/wp-config.php"
chmod 664 "$site/wp-config.php"

# Exercise the ordinary-upgrade gate itself: root mode must not touch the
# config, while non-root mode converges default and explicit-opt-in modes.
eval "$(sed -n '/^upgrade_harden_wp_config_permissions() {/,/^}/p' upgrade.sh)"
LOCAL_MODE=false PLUGINS_ONLY=false ROADIE_ONLY=false SKILLS_ONLY=false
AGENTS_MD_ONLY=false RECONCILE_SERVICES_ONLY=false SITE_PATH="$site"
eval "$(sed -n '/^harden_wp_config_permissions() {/,/^}/p' lib/wordpress.sh)"
RUN_AS_ROOT=true
chmod 600 "$site/wp-config.php"
upgrade_harden_wp_config_permissions
[ "$(mode_of "$site/wp-config.php")" = "600" ] || fail "root-mode ordinary upgrade must not change wp-config.php permissions"
RUN_AS_ROOT=false
OWNED_WRITABLE=""
chmod 666 "$site/wp-config.php"
upgrade_harden_wp_config_permissions
[ "$(mode_of "$site/wp-config.php")" = "640" ] || fail "non-root ordinary upgrade must converge default to 0640"
OWNED_WRITABLE=wp-config.php
chmod 640 "$site/wp-config.php"
upgrade_harden_wp_config_permissions
[ "$(mode_of "$site/wp-config.php")" = "660" ] || fail "non-root ordinary upgrade must converge opt-in to 0660"
OWNED_WRITABLE=""

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

# ---------------------------------------------------------------------------
# 6. The site root's own directory carries the sharing contract (#644). setup's
#    one-time recursive grant does not survive an external directory
#    replacement, so the ordinary upgrade converges the root directory's
#    group-write bit: additive and non-recursive, with ownership, the setgid
#    bit, unrelated children, and the hardened config untouched. A root this
#    identity cannot chmod produces one clear root-repair result.
# ---------------------------------------------------------------------------
eval "$(sed -n '/^ensure_site_root_group_write() {/,/^}/p' lib/wordpress.sh)"
eval "$(sed -n '/^upgrade_ensure_site_root_group_write() {/,/^}/p' upgrade.sh)"

root_site="$TMP/owned-site"
mkdir -p "$root_site/wp-content/uploads"
printf '<?php // credentials\n' > "$root_site/wp-config.php"
printf 'x' > "$root_site/wp-content/uploads/keep.txt"
chmod 2755 "$root_site" "$root_site/wp-content"
chmod 640 "$root_site/wp-config.php"
chmod 664 "$root_site/wp-content/uploads/keep.txt"
LOCAL_MODE=false PLUGINS_ONLY=false ROADIE_ONLY=false SKILLS_ONLY=false
AGENTS_MD_ONLY=false RECONCILE_SERVICES_ONLY=false RUN_AS_ROOT=false
SITE_PATH="$root_site"
DRY_RUN=false

# The ordinary-upgrade wrapper runs the convergence for a non-root install
# and records repair-or-report into the summary arrays the run prints.
# Expected repair = the drifted mode with exactly the group-write bit added,
# so special bits and owner bits are asserted preserved whatever the
# filesystem decides to keep (some strip setgid at chmod time).
group_write_added() {
  local mode="$1"
  printf '%s%s%s' "${mode:0:${#mode}-2}" "$(( ${mode: -2:1} | 2 ))" "${mode: -1}"
}
chmod 2755 "$root_site" "$root_site/wp-content"
drifted_root="$(file_mode "$root_site")"
drifted_child="$(file_mode "$root_site/wp-content")"
UPDATED_ITEMS=()
PENDING_ITEMS=()
upgrade_ensure_site_root_group_write
[ "$(file_mode "$root_site")" = "$(group_write_added "$drifted_root")" ] \
  || fail "site root must gain group-write and nothing else: $(file_mode "$root_site") vs drift $drifted_root"
[ "$(file_mode "$root_site/wp-content")" = "$drifted_child" ] || fail "non-recursive repair must not touch children, got $(file_mode "$root_site/wp-content")"
[ "$(file_mode "$root_site/wp-config.php")" = 640 ] || fail "root repair must not reach wp-config.php, got $(file_mode "$root_site/wp-config.php")"
[ "$(file_mode "$root_site/wp-content/uploads/keep.txt")" = 664 ] || fail "unrelated child files must be untouched"
[ "${UPDATED_ITEMS[*]}" = "Site root group-write re-asserted ($root_site)" ] || fail "repair must be reported: ${UPDATED_ITEMS[*]:-none}"
[ "${#PENDING_ITEMS[@]}" -eq 0 ] || fail "an identity that can repair must not request root repair"

# Already-correct roots are a no-op, so repeated application converges.
UPDATED_ITEMS=()
upgrade_ensure_site_root_group_write
[ "$(file_mode "$root_site")" = "$(group_write_added "$drifted_root")" ] || fail "repeat application must keep the converged mode"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "no-op convergence must not report a change"

# Drift the production way: only the root loses group-write while children
# keep theirs. An identity that cannot chmod a foreign-owned directory gets
# one machine-readable root-repair result and the mode stays untouched.
if [ "$(id -u)" -ne 0 ]; then
  chmod 2755 "$root_site"
  drifted_again="$(file_mode "$root_site")"
  PENDING_ITEMS=()
  id() { [ "${1:-}" != -u ] || { printf '4242\n'; return; }; command id "$@"; }
  # Direct call, not command substitution: the summary arrays must be mutated
  # in this shell, exactly as upgrade.sh runs the wrapper.
  upgrade_ensure_site_root_group_write > "$TMP/repair.out" 2>&1
  unset -f id
  [ "$(file_mode "$root_site")" = "$drifted_again" ] \
    || fail "a foreign-owned root must not be mutated by this identity"
  [ "${#PENDING_ITEMS[@]}" -eq 1 ] || fail "exactly one pending root-repair item expected: ${PENDING_ITEMS[*]:-none}"
  case "${PENDING_ITEMS[0]}" in
    "Site root group-write (root): sudo chmod g+w"*) : ;;
    *) fail "pending item must carry the repair command: ${PENDING_ITEMS[0]}" ;;
  esac
  case "$(cat "$TMP/repair.out")" in
    *'"status":"root_repair_required","component":"site_root_group_write"'*) : ;;
    *) fail "no machine-readable root_repair_required record: $(cat "$TMP/repair.out")" ;;
  esac
  case "$(cat "$TMP/repair.out")" in
    *sudo\ chmod\ g+w*) : ;;
    *) fail "root-repair output must name the exact command: $(cat "$TMP/repair.out")" ;;
  esac

  # Root can repair it: a root-run upgrade of the same drift applies the bit
  # directly. Not exercisable without a real root identity, so the seam is
  # only asserted when the suite itself runs unprivileged.
  :
else
  chmod 2755 "$root_site"
  chown nobody:nogroup "$root_site" 2>/dev/null || chown nobody "$root_site" 2>/dev/null || true
  repair_out="$(upgrade_ensure_site_root_group_write 2>&1)"
  [ "$(file_mode "$root_site")" = 2775 ] || fail "root must repair a foreign-owned drifted root, got $(file_mode "$root_site")"
  chown "$(id -un)" "$root_site"
fi

# Dry-run must not mutate the drifted root.
chmod 2755 "$root_site"
drifted_dry="$(file_mode "$root_site")"
DRY_RUN=true
UPDATED_ITEMS=()
PENDING_ITEMS=()
upgrade_ensure_site_root_group_write >/dev/null 2>&1
DRY_RUN=false
[ "$(file_mode "$root_site")" = "$drifted_dry" ] || fail "dry-run must not mutate the site root"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] && [ "${#PENDING_ITEMS[@]}" -eq 0 ] || fail "dry-run must not report repair or change"

# Local mode and *-only operations are outside the sharing contract: the
# wrapper must not touch the site at all.
chmod 2755 "$root_site"
drifted_scoped="$(file_mode "$root_site")"
LOCAL_MODE=true
upgrade_ensure_site_root_group_write
LOCAL_MODE=false
[ "$(file_mode "$root_site")" = "$drifted_scoped" ] || fail "local mode must not converge the site root"
EXTERNAL_WORDPRESS=true
upgrade_ensure_site_root_group_write
EXTERNAL_WORDPRESS=false
[ "$(file_mode "$root_site")" = "$drifted_scoped" ] || fail "external runtime must not converge a remote site's root"
ROADIE_ONLY=true
upgrade_ensure_site_root_group_write
ROADIE_ONLY=false
[ "$(file_mode "$root_site")" = "$drifted_scoped" ] || fail "scoped operations must not converge the site root"
AGENTS_MD_ONLY=true
upgrade_ensure_site_root_group_write
AGENTS_MD_ONLY=false
[ "$(file_mode "$root_site")" = "$(group_write_added "$drifted_scoped")" ] || fail "guidance-only upgrade must restore the directory needed for composition"

# Real Linux identities prove the atomic-replacement seam, rather than merely
# asserting that the mode has the expected shape.
if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
  shared="$TMP/shared-site"
  mkdir "$shared"
  printf original > "$shared/AGENTS.md"
  chown "root:$(id -gn nobody)" "$shared"
  chmod o+rx "$TMP"
  chmod 2755 "$shared"
  compose='file=$(mktemp "$1/.agents.XXXXXX") && printf composed > "$file" && mv "$file" "$1/AGENTS.md"'
  if runuser -u nobody -- sh -c "$compose" sh "$shared" 2>/dev/null; then
    fail "non-root composition unexpectedly succeeded before directory repair"
  fi
  ensure_site_root_group_write "$shared"
  runuser -u nobody -- sh -c "$compose" sh "$shared" || fail "non-root atomic replacement failed after repair"
  [ "$(cat "$shared/AGENTS.md")" = composed ] || fail "atomic replacement did not install the composed content"
  echo "real non-root atomic AGENTS.md replacement passed"
fi

echo "site-root group-write convergence tests passed"

echo "wp-config permissions tests passed"
