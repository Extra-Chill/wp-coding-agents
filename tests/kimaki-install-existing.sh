#!/bin/bash
# An installed Kimaki may keep running after printing --version. Detection must
# not launch it just to decorate setup logs.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/kimaki" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  touch "$TEST_TMP/version-invoked"
  sleep 30
fi
SH
chmod +x "$TMP/bin/kimaki"

export TEST_TMP="$TMP"
export PATH="$TMP/bin:/usr/bin:/bin"
export DRY_RUN=false
export EXTERNAL_WORDPRESS=true
export LOCAL_MODE=false
export PLATFORM=linux

log() { :; }
run_cmd() { "$@"; }
external_wordpress_kimaki_command() { printf 'kimaki'; }

source "$ROOT/bridges/kimaki.sh"
_kimaki_sync_bin_helpers() { :; }

bridge_install
test ! -e "$TMP/version-invoked"

echo "PASS: tests/kimaki-install-existing.sh"
