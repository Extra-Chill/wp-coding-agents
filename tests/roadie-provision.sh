#!/bin/bash
# tests/roadie-provision.sh — Roadie is installed from the pinned release.
#
# VPS installs put the pinned release tarball into a root-owned, world-readable
# system prefix: the service user runs it, the web user runs `roadie send` from
# it, and Roadie never upgrades itself (ROADIE_MANAGED=1). Local installs use
# the user's global npm. The installed version is read from package.json, so
# detection never launches the binary (an installed bridge may keep running
# after printing --version).
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
source "$SCRIPT_DIR/bridges/roadie.sh"

log() { :; }
warn() { printf 'WARN: %s\n' "$*" >> "$TMP/warn.log"; }
DRY_RUN=false
UPDATED_ITEMS=()
PENDING_ITEMS=()
SITE_PATH="$TMP/site"

# Fake npm: records argv and lays out a package at the requested prefix.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
if [ "$1" = root ]; then printf '%s\n' "$FAKE_GLOBAL_ROOT"; exit 0; fi
prefix=""
while [ $# -gt 0 ]; do
  [ "$1" = --prefix ] && prefix="$2"
  shift
done
[ -n "$prefix" ] || exit 0
mkdir -p "$prefix/lib/node_modules/@extrachill/roadie" "$prefix/bin"
printf '{"version":"%s"}\n' "$FAKE_VERSION" > "$prefix/lib/node_modules/@extrachill/roadie/package.json"
printf '#!/bin/sh\ntouch "%s"\n' "$VERSION_PROBE" > "$prefix/bin/roadie"
chmod 0700 "$prefix/bin/roadie"
SH
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH" NPM_LOG="$TMP/npm.log" VERSION_PROBE="$TMP/version-invoked"
export FAKE_GLOBAL_ROOT="$TMP/global/lib/node_modules"

PIN="$(tr -d '[:space:]' < "$SCRIPT_DIR/bridges/roadie/roadie-version")"
export FAKE_VERSION="$PIN"
URL="https://github.com/Extra-Chill/roadie/releases/download/v$PIN/extrachill-roadie-$PIN.tgz"

echo "==> pin and release URL"
[ "$(roadie_pinned_version)" = "$PIN" ]; check $? "pinned version comes from bridges/roadie/roadie-version ($PIN)"
[ "$(roadie_release_url)" = "$URL" ]; check $? "release URL is the pinned tarball"

echo "==> VPS root install goes into the system prefix"
LOCAL_MODE=false
ROADIE_SYSTEM_PREFIX="$TMP/prefix"
WP_CODING_AGENTS_TEST_EUID=0
_roadie_provision_package
grep -qxF "install -g --prefix $TMP/prefix $URL" "$NPM_LOG"; check $? "npm installs the pinned tarball into the system prefix"
[ "$(_roadie_installed_version)" = "$PIN" ]; check $? "installed version read from package.json"
[ "$(stat -c %a "$TMP/prefix/bin/roadie" 2>/dev/null || stat -f %Lp "$TMP/prefix/bin/roadie")" = 755 ]; check $? "prefix is made world-readable (binary 0700 -> 0755)"
[ "$(roadie_bin)" = "$TMP/prefix/bin/roadie" ]; check $? "roadie_bin is the system-prefix binary"
[ ! -e "$VERSION_PROBE" ]; check $? "detection never launched the binary"

echo "==> re-run at the pinned version is a no-op"
: > "$NPM_LOG"
_roadie_provision_package
[ ! -s "$NPM_LOG" ]; check $? "no npm call when the pinned version is installed"

echo "==> a non-root upgrade reports a root repair instead of installing"
printf '{"version":"0.0.1"}\n' > "$TMP/prefix/lib/node_modules/@extrachill/roadie/package.json"
: > "$NPM_LOG"
WP_CODING_AGENTS_TEST_EUID=1000
PENDING_ITEMS=()
_roadie_provision_package
[ ! -s "$NPM_LOG" ]; check $? "no npm call without root"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -qF "Roadie $PIN install (root)"; check $? "pending item names the pinned version"
grep -qF -- "--roadie-only" "$TMP/warn.log"; check $? "warning gives the --roadie-only root repair command"

echo "==> local install uses the user's global npm"
LOCAL_MODE=true
WP_CODING_AGENTS_TEST_EUID=1000
: > "$NPM_LOG"
_roadie_provision_package
grep -qxF "install -g $URL" "$NPM_LOG"; check $? "npm install -g of the pinned tarball, no prefix"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-provision.sh ($PASS assertions)"
