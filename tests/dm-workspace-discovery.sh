#!/bin/bash
# tests/dm-workspace-discovery.sh — canonical DMC workspace root discovery.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php"

export SITE_PATH
export DRY_RUN=false

wp_cmd() {
  if [ "$*" != "datamachine-code workspace path" ]; then
    echo "unexpected wp_cmd call: $*" >&2
    return 1
  fi
  printf '%s\n' "$TMP/Developer"
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/data-machine.sh"

DM_WORKSPACE_DIR="$TMP/.datamachine/workspace"
DATAMACHINE_WORKSPACE_PATH=""
discover_dm_workspace_dir
if [ "$DM_WORKSPACE_DIR" != "$TMP/Developer" ]; then
  echo "FAIL: canonical DMC workspace was not discovered: $DM_WORKSPACE_DIR"
  exit 1
fi

DATAMACHINE_WORKSPACE_PATH="$TMP/explicit-workspace"
DM_WORKSPACE_DIR="$TMP/Developer"
discover_dm_workspace_dir
if [ "$DM_WORKSPACE_DIR" != "$TMP/explicit-workspace" ]; then
  echo "FAIL: explicit workspace path was not authoritative: $DM_WORKSPACE_DIR"
  exit 1
fi

echo "PASS: tests/dm-workspace-discovery.sh"
