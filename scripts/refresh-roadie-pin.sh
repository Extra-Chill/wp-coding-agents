#!/bin/bash
# scripts/refresh-roadie-pin.sh — move bridges/roadie/roadie-version to Roadie's
# newest published release.
#
# The pin stays: every install from the same wp-coding-agents commit gets the
# same Roadie. This keeps it current without anyone editing it. Roadie never
# tells this repository about a release; the refresh workflow asks.
#
# Exit 0 with the pin unchanged when it is already current. Exit non-zero, pin
# untouched, when the newest release cannot be resolved, is not a plain
# version, is older than the pin, or lacks the tarball setup installs.
#
# Output on stdout: the pinned version after the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$SCRIPT_DIR/bridges/roadie/roadie-version"
REPO="${ROADIE_RELEASE_REPO:-Extra-Chill/roadie}"

fail() { echo "refresh-roadie-pin: $*" >&2; exit 1; }

current="$(tr -d '[:space:]' < "$PIN_FILE")"
[ -n "$current" ] || fail "pin file is empty: $PIN_FILE"

tag="$(gh api "repos/$REPO/releases/latest" --jq .tag_name)" || fail "could not resolve the newest $REPO release"
latest="${tag#v}"
[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "newest release tag is not a plain version: $tag"

if [ "$latest" = "$current" ]; then
  echo "$current"
  exit 0
fi
newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)"
[ "$newest" = "$latest" ] || fail "newest release $latest is older than the pin $current"

asset="extrachill-roadie-$latest.tgz"
gh api "repos/$REPO/releases/tags/v$latest" --jq '.assets[].name' | grep -qxF "$asset" \
  || fail "release v$latest has no $asset yet"

printf '%s\n' "$latest" > "$PIN_FILE"
echo "$latest"
