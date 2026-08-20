#!/bin/bash
# PHP detection must not contact package repositories when dependencies are skipped.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { :; }
warn() { :; }
command() {
  if [ "$1" = -v ] && [ "$2" = php ]; then
    return 1
  fi
  builtin command "$@"
}
apt() {
  printf 'apt\n' >> "$TMP/calls"
}
apt-cache() {
  printf 'php8.4-fpm - server-side scripting language\n'
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/detect.sh"

PLATFORM=linux
DRY_RUN=false
SKIP_DEPS=true
PHP_VERSION=stale
detect_php_version
[ -z "$PHP_VERSION" ] || { echo "FAIL: skipped detection retained a stale PHP version"; exit 1; }
[ ! -e "$TMP/calls" ] || { echo "FAIL: skipped dependency detection invoked apt"; exit 1; }

SKIP_DEPS=false
detect_php_version
[ "$PHP_VERSION" = 8.4 ] || { echo "FAIL: package detection did not select the available PHP version"; exit 1; }
[ "$(cat "$TMP/calls")" = apt ] || { echo "FAIL: package detection did not refresh apt metadata"; exit 1; }

echo "PASS: PHP detection honors dependency policy"
