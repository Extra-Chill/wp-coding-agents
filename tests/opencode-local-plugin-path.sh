#!/bin/bash
# tests/opencode-local-plugin-path.sh — local opencode.json uses durable plugins.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
KIMAKI_DATA_DIR="$TMP/kimaki-data"
mkdir -p "$SITE_PATH" "$KIMAKI_DATA_DIR"

export SCRIPT_DIR
export SITE_PATH
export KIMAKI_DATA_DIR
export CHAT_BRIDGE="kimaki"
export LOCAL_MODE=true
export DRY_RUN=false
export OPENCODE_MODEL=""
export OPENCODE_SMALL_MODEL=""
export DM_WORKSPACE_DIR="$TMP/workspace"
export DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md"

log() { :; }
warn() { printf '%s\n' "$*" >&2; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtimes/opencode.sh"

runtime_generate_config

python3 - "$SITE_PATH/opencode.json" "$KIMAKI_DATA_DIR" <<'PY'
import json
import sys

opencode_json, kimaki_data_dir = sys.argv[1], sys.argv[2]
with open(opencode_json, encoding="utf-8") as handle:
    data = json.load(handle)

expected = [
    f"{kimaki_data_dir}/kimaki-config/plugins/dm-context-filter.ts",
    f"{kimaki_data_dir}/kimaki-config/plugins/dm-agent-sync.ts",
]
actual = data.get("plugin")
if actual != expected:
    raise SystemExit(f"unexpected local plugin paths: {actual}")
PY

echo "PASS: tests/opencode-local-plugin-path.sh"
