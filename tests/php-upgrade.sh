#!/bin/bash
# tests/php-upgrade.sh — the agent can apply PHP security patches, and only that.
#
# Installer: the root-owned command and a sudoers grant limited to `start` and
# `status` are installed only on a managed VPS with a non-root service user.
# Wrapper: rejects every argument shape it does not own, upgrades only the
# already-installed versioned php<ver>-* packages with --only-upgrade and
# --no-remove, and tests each FPM config before restarting it.
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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/php-upgrade.sh"

log() { :; }
warn() { printf '%s\n' "$*" >> "$TMP/warn.log"; }
chown() { :; }            # the test is not root
DRY_RUN=false
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
SERVICE_USER=pi
GRANTS_SUDOERS_DIR="$TMP/sudoers.d"
PHP_UPGRADE_BIN="$TMP/sbin/wp-coding-agents-php-upgrade"
export WP_CODING_AGENTS_TEST_EUID=0
reset() { rm -rf "$TMP/sbin" "$TMP/sudoers.d" "$TMP/warn.log"; GRANT_DECLARED_NAMES=(); GRANT_DECLARED_CONTENT=(); }
W="$SCRIPT_DIR/scripts/wp-coding-agents-php-upgrade"
GRANT="$GRANTS_SUDOERS_DIR/wp-coding-agents-php-upgrade"

echo "==> installs on a managed VPS"
reset; php_upgrade_apply
cmp -s "$W" "$PHP_UPGRADE_BIN"; check $? "wrapper installed verbatim"
[ "$(stat -c %a "$PHP_UPGRADE_BIN" 2>/dev/null || stat -f %Lp "$PHP_UPGRADE_BIN")" = 755 ]; check $? "wrapper is 0755"
[ "$(cat "$GRANT")" = "pi ALL=(root) NOPASSWD: $PHP_UPGRADE_BIN start, $PHP_UPGRADE_BIN status" ]; check $? "grant allows exactly start and status"
[ "$(stat -c %a "$GRANT" 2>/dev/null || stat -f %Lp "$GRANT")" = 440 ]; check $? "grant is 0440"
grep -q "apply\|\*" "$GRANT"; [ $? -ne 0 ]; check $? "grant has no wildcard and no apply"
[ "$(grant_declared_content wp-coding-agents-php-upgrade)" = "$(cat "$GRANT")" ]; check $? "installed grant equals its declaration"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$GRANT" >/dev/null 2>&1; check $? "grant passes visudo"
fi
php_upgrade_apply
[ "$(wc -l < "$GRANT" | tr -d ' ')" = 1 ]; check $? "re-running is idempotent"

echo "==> scope"
reset; ( LOCAL_MODE=true; php_upgrade_apply ); [ ! -e "$PHP_UPGRADE_BIN" ] && [ ! -e "$GRANT" ]; check $? "local installs: nothing"
reset; ( SERVICE_USER=root; php_upgrade_apply ); [ ! -e "$PHP_UPGRADE_BIN" ]; check $? "root service user: no grant needed"
reset; ( EXTERNAL_WORDPRESS=true; php_upgrade_apply ); [ ! -e "$PHP_UPGRADE_BIN" ]; check $? "external WordPress: nothing"
reset; ( WP_CODING_AGENTS_TEST_EUID=1000; php_upgrade_apply ); [ ! -e "$PHP_UPGRADE_BIN" ]; check $? "non-root run: nothing"
reset; ( DRY_RUN=true; php_upgrade_apply ) >/dev/null; [ ! -e "$PHP_UPGRADE_BIN" ] && [ ! -e "$GRANT" ]; check $? "dry run: nothing"
reset; ( grant_validate() { return 1; }; php_upgrade_apply ); [ ! -e "$GRANT" ] && grep -q "refused" "$TMP/warn.log"; check $? "a refused grant is reported, not installed"

echo "==> setup and upgrade run the installer"
grep -q ' self-upgrade php-upgrade ' "$SCRIPT_DIR/setup.sh"; check $? "setup.sh loads lib/php-upgrade.sh after self-upgrade"
grep -q ' self-upgrade php-upgrade ' "$SCRIPT_DIR/upgrade.sh"; check $? "upgrade.sh loads lib/php-upgrade.sh after self-upgrade"
grep -q 'php_upgrade_apply' "$SCRIPT_DIR/setup.sh"; check $? "setup.sh calls php_upgrade_apply"
grep -q 'php_upgrade_apply' "$SCRIPT_DIR/upgrade.sh"; check $? "upgrade.sh calls php_upgrade_apply"

echo "==> wrapper argument and privilege surface"
bash -n "$W"; check $? "wrapper parses"
for args in "" "frobnicate" "start now" "start php8.5-fpm" "status --all" "apply x" "apply php8.4-fpm=8.5.0" "--help"; do
  # shellcheck disable=SC2086
  bash "$W" $args >/dev/null 2>&1; [ $? -eq 2 ]; check $? "rejects '${args}'"
done
if [ "$(id -u)" -ne 0 ]; then
  bash "$W" start 2>&1 | grep -q "must run as root"; check $? "start refuses without root"
  bash "$W" apply 2>&1 | grep -q "must run as root"; check $? "apply refuses without root"
  bash "$W" status | head -1 | grep -qx "idle\|running"; check $? "status works unprivileged"
fi
grep -q 'grep -q "/$UNIT.service\\$" /proc/self/cgroup' "$W"; check $? "apply only runs inside its own transient unit"
grep -q 'systemd-run --unit="$UNIT"' "$W"; check $? "start launches a transient systemd unit"
grep -q 'readonly PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$W"; check $? "PATH is fixed"
grep -q 'unset BASH_ENV CDPATH ENV LD_PRELOAD' "$W"; check $? "dangerous environment is cleared"

echo "==> package selection: installed, versioned php<ver>-* only"
eval "$(sed -n '/^php_packages() {/,/^}/p' "$W")"
eval "$(sed -n '/^php_fpm_versions() {/,/^}/p' "$W")"
eval "$(sed -n '/^apt_upgrade_args() {/,/^}/p' "$W")"
dpkg-query() {
  cat <<'EOF'
ii  php8.4-fpm
ii  php8.4-mysql
ii  php8.4-common
ii  php8.4-opcache
rc  php8.3-fpm
un  php8.5-cli
ii  php
ii  php-common
ii  php-pear
ii  libapache2-mod-php8.4
ii  nginx
ii  php8.4-fpm
EOF
}
PKGS="$(php_packages)"
[ "$PKGS" = "$(printf 'php8.4-common\nphp8.4-fpm\nphp8.4-mysql\nphp8.4-opcache')" ]; check $? "only installed (ii) php<major>.<minor>-* packages, deduplicated"
printf '%s\n' "$PKGS" | grep -qx 'php8.3-fpm'; [ $? -ne 0 ]; check $? "removed-but-configured (rc) packages are not reinstalled"
printf '%s\n' "$PKGS" | grep -qx 'php8.5-cli'; [ $? -ne 0 ]; check $? "a newer PHP minor is never selected"
printf '%s\n' "$PKGS" | grep -qx 'php\|php-common\|php-pear'; [ $? -ne 0 ]; check $? "unversioned metapackages (which move the minor) are excluded"
[ "$(php_fpm_versions)" = "8.4" ]; check $? "FPM versions come from installed php<ver>-fpm"

echo "==> the exact apt command"
mapfile -t ARGS < <(apt_upgrade_args php8.4-fpm php8.4-mysql)
[ "${ARGS[*]}" = "install --only-upgrade --no-remove -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold php8.4-fpm php8.4-mysql" ]; check $? "apt-get install --only-upgrade --no-remove, non-interactive conffile policy, named packages only"
apply_body="$(sed -n '/^cmd_apply() {/,/^}/p' "$W")"
printf '%s\n' "$apply_body" | grep -q 'DEBIAN_FRONTEND=noninteractive'; check $? "apply is non-interactive"
printf '%s\n' "$apply_body" | grep -q 'apt-get update'; check $? "apply refreshes package lists first"
printf '%s\n' "$apply_body" | grep -q 'apt-get "${args\[@\]}"'; check $? "apply runs apt-get with only the computed arguments"
printf '%s\n' "$apply_body" | grep -n 'php-fpm$version" -t\|systemctl restart' | head -1 | grep -q -- '-t'; check $? "FPM config is tested before restart"
grep -q 'dist-upgrade\|full-upgrade\|autoremove\|apt-get upgrade\|apt-get remove\|apt-get purge' "$W"; [ $? -ne 0 ]; check $? "no broad upgrade or removal verbs in the wrapper"

echo
if [ "$FAIL" -gt 0 ]; then echo "FAIL: $FAIL assertion(s)"; exit 1; fi
echo "PASS: tests/php-upgrade.sh ($PASS assertions)"
