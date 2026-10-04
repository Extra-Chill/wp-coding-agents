#!/bin/bash
# tests/self-upgrade.sh — the agent can upgrade its own install, and only that.
#
# Installer: the root-owned command, its config, and a sudoers grant limited to
# `start` and `status` are installed only on a managed VPS with a non-root
# service user and a locked-down checkout. Wrapper: rejects every argument
# shape it does not own, and refuses to run privileged steps without root.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-upgrade.sh"

log() { :; }
warn() { printf '%s\n' "$*" >> "$TMP/warn.log"; }
chown() { :; }            # the test is not root; ownership is stubbed below
DRY_RUN=false
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
SERVICE_USER=opencode
SITE_PATH=/var/www/site
GRANTS_SUDOERS_DIR="$TMP/sudoers.d"
SELF_UPGRADE_BIN="$TMP/sbin/wp-coding-agents-upgrade"
SELF_UPGRADE_CONFIG="$TMP/etc/self-upgrade.conf"
export WP_CODING_AGENTS_TEST_EUID=0
OWNER=root
file_owner() { printf '%s\n' "$OWNER"; }
file_mode() { printf '755\n'; }
mkdir -p "$TMP/checkout/.git"
SCRIPT_DIR_REAL="$SCRIPT_DIR"
reset() { rm -rf "$TMP/sbin" "$TMP/etc" "$TMP/sudoers.d" "$TMP/warn.log"; }

run_apply() { ( SCRIPT_DIR="$1"; self_upgrade_apply ); }

echo "==> installs on a managed VPS with a locked checkout"
# The installer reads the wrapper from SCRIPT_DIR/scripts, so point at the repo
# but stub the lock check's ownership view (the repo is not root-owned here).
run_apply "$SCRIPT_DIR_REAL"
cmp -s "$SCRIPT_DIR_REAL/scripts/wp-coding-agents-upgrade" "$SELF_UPGRADE_BIN"; check $? "wrapper installed verbatim"
[ "$(stat -c %a "$SELF_UPGRADE_BIN" 2>/dev/null || stat -f %Lp "$SELF_UPGRADE_BIN")" = 755 ]; check $? "wrapper is 0755"
[ "$(cat "$SELF_UPGRADE_CONFIG")" = "$(printf 'CHECKOUT=%s\nSITE_PATH=/var/www/site\nTRUST_REF=main' "$SCRIPT_DIR_REAL")" ]; check $? "config names checkout, site, and trust ref main"
GRANT="$GRANTS_SUDOERS_DIR/wp-coding-agents-self-upgrade"
[ "$(cat "$GRANT")" = "opencode ALL=(root) NOPASSWD: $SELF_UPGRADE_BIN start, $SELF_UPGRADE_BIN status" ]; check $? "grant allows exactly start and status"
[ "$(stat -c %a "$GRANT" 2>/dev/null || stat -f %Lp "$GRANT")" = 440 ]; check $? "grant is 0440"
grep -q "apply\|\*" "$GRANT"; [ $? -ne 0 ]; check $? "grant has no wildcard and no apply"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$GRANT" >/dev/null 2>&1; check $? "grant passes visudo"
fi

echo "==> refuses when the checkout is not locked down"
reset; OWNER=opencode
run_apply "$SCRIPT_DIR_REAL"
[ ! -e "$SELF_UPGRADE_BIN" ] && [ ! -e "$GRANTS_SUDOERS_DIR" ]; check $? "nothing installed for an agent-writable checkout"
grep -q "root-owned git checkout" "$TMP/warn.log"; check $? "operator told why"
OWNER=root

echo "==> scope"
reset; ( LOCAL_MODE=true; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "local installs: nothing"
reset; ( SERVICE_USER=root; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "root service user: no grant needed"
reset; ( EXTERNAL_WORDPRESS=true; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "external WordPress: nothing"
reset; ( WP_CODING_AGENTS_TEST_EUID=1000; run_apply "$SCRIPT_DIR_REAL" ); [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "non-root run: nothing"
reset; mkdir -p "$TMP/etc"; printf 'SITE_PATH=/var/www/other\n' > "$SELF_UPGRADE_CONFIG"
run_apply "$SCRIPT_DIR_REAL"
grep -q "other" "$SELF_UPGRADE_CONFIG" && [ ! -e "$SELF_UPGRADE_BIN" ]; check $? "a second site does not take over the first site's config"

echo "==> wrapper argument and privilege surface"
W="$SCRIPT_DIR_REAL/scripts/wp-coding-agents-upgrade"
bash -n "$W"; check $? "wrapper parses"
for args in "" "frobnicate" "start now" "status --all" "apply x"; do
  # shellcheck disable=SC2086
  bash "$W" $args >/dev/null 2>&1; [ $? -eq 2 ]; check $? "rejects '${args}'"
done
if [ "$(id -u)" -ne 0 ]; then
  bash "$W" start 2>&1 | grep -q "must run as root"; check $? "start refuses without root"
  bash "$W" apply 2>&1 | grep -q "must run as root"; check $? "apply refuses without root"
  bash "$W" status | head -1 | grep -qx "idle\|running"; check $? "status works unprivileged"
fi
grep -q 'grep -q "/$UNIT.service\\$" /proc/self/cgroup' "$W"; check $? "apply only runs inside its own transient unit"
grep -q 'checkout --quiet --force --detach "origin/$TRUST_REF"' "$W"; check $? "runs only the fetched trust ref"

echo "==> installer tools use locked local prefixes, not the caller PATH"
eval "$(sed -n '/^installer_path() {/,/^}/p' "$W")"
root_locked() { [ "${DENIED_PREFIX:-}" != "$1" ]; }
die() { printf '%s\n' "$1" >&2; exit "$2"; }
BOOTSTRAP_PATH=/usr/sbin:/usr/bin:/sbin:/bin
CHILD_PATH="$(PATH="$BOOTSTRAP_PATH" installer_path)"
[ "$CHILD_PATH" = "/usr/local/sbin:/usr/local/bin:$BOOTSTRAP_PATH" ]; check $? "installer receives setup's local prefixes with the fixed bootstrap tail"
env PATH="$CHILD_PATH" sh -c 'command -v sh >/dev/null'; check $? "installer child can resolve tools through the admitted PATH"
if [ -d /usr/local/bin ]; then
  ( DENIED_PREFIX=/usr/local/bin; PATH="$BOOTSTRAP_PATH" installer_path ) >"$TMP/path.out" 2>&1
  [ $? -eq 2 ]; check $? "an unlocked executable prefix is refused before the installer starts"
fi
if [ -d /usr/local ]; then
  ( DENIED_PREFIX=/usr/local; PATH="$BOOTSTRAP_PATH" installer_path ) >"$TMP/path.out" 2>&1
  [ $? -eq 2 ]; check $? "an unlocked parent of executable prefixes is refused"
fi

echo
if [ "$FAIL" -gt 0 ]; then echo "FAIL: $FAIL assertion(s)"; exit 1; fi
echo "PASS: tests/self-upgrade.sh ($PASS assertions)"
