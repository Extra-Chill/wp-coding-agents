#!/bin/bash
# scripts/refresh-pi-pin.sh — move bridges/roadie/pi-version to the newest
# published release of the Pi agent backend Roadie runs.
#
# The pin stays: every install from the same wp-coding-agents commit gets the
# same Pi. This keeps it current within its major version. Roadie drives Pi
# over its RPC protocol, so a new major is a contract change: the script
# refuses it and a person moves the pin alongside any Roadie change it needs.
#
# Exit 0 with the pin unchanged when it is already current. Exit non-zero, pin
# untouched, when the newest release cannot be resolved, is not a plain
# version, is older than the pin, or is a different major version.
#
# Output on stdout: the pinned version after the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$SCRIPT_DIR/bridges/roadie/pi-version"
PACKAGE="${PI_PACKAGE_NAME:-@earendil-works/pi-coding-agent}"

fail() { echo "refresh-pi-pin: $*" >&2; exit 1; }

current="$(tr -d '[:space:]' < "$PIN_FILE")"
[ -n "$current" ] || fail "pin file is empty: $PIN_FILE"

latest="$(npm view "$PACKAGE" version 2>/dev/null)" || fail "could not resolve the newest $PACKAGE release"
latest="$(printf '%s' "$latest" | tr -d '[:space:]')"
[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "newest release is not a plain version: $latest"

if [ "$latest" = "$current" ]; then
  echo "$current"
  exit 0
fi
newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)"
[ "$newest" = "$latest" ] || fail "newest release $latest is older than the pin $current"
[ "${latest%%.*}" = "${current%%.*}" ] || fail "newest release $latest is a new major version; move the pin from $current by hand"

printf '%s\n' "$latest" > "$PIN_FILE"
echo "$latest"
