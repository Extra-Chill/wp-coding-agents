#!/bin/bash
# tests/opencode-local-plugin-path.sh — local opencode.json uses durable plugins.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
KIMAKI_DATA_DIR="$TMP/kimaki-data"
WORKSPACE_REPOSITORY="$TMP/workspace"
mkdir -p "$SITE_PATH" "$KIMAKI_DATA_DIR" "$WORKSPACE_REPOSITORY"
git -C "$WORKSPACE_REPOSITORY" init -q

export SCRIPT_DIR
export SITE_PATH
export KIMAKI_DATA_DIR
export CHAT_BRIDGE="kimaki"
export LOCAL_MODE=true
export DRY_RUN=false
export OPENCODE_MODEL=""
export OPENCODE_SMALL_MODEL=""
export WORKSPACE_REPOSITORIES="$WORKSPACE_REPOSITORY"
export DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md"
export WITH_CLAUDE_CODE_AUTH=true
export RUNTIME="opencode"
UPDATED_ITEMS=()

log() { :; }
warn() { printf '%s\n' "$*" >&2; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
SOURCE_MODE="${SOURCE_MODE:-workspace}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtimes/opencode.sh"

runtime_generate_config

python3 - "$SITE_PATH/opencode.json" "$KIMAKI_DATA_DIR" "$WORKSPACE_REPOSITORY" <<'PY'
import json
import os
import sys

opencode_json, kimaki_data_dir, workspace_repository = sys.argv[1:]
with open(opencode_json, encoding="utf-8") as handle:
    data = json.load(handle)

expected = [
    f"{kimaki_data_dir}/kimaki-config/plugins/dm-context-filter.ts",
    f"{kimaki_data_dir}/kimaki-config/plugins/dm-agent-sync.ts",
    f"{kimaki_data_dir}/kimaki-config/plugins/kimaki-session-attribution.ts",
    f"{opencode_json.rsplit('/', 1)[0]}/.opencode/plugins/claude-code-auth.ts",
]
actual = data.get("plugin")
if actual != expected:
    raise SystemExit(f"unexpected local plugin paths: {actual}")

external = data.get("permission", {}).get("external_directory", {})
expected_workspace = os.path.normpath(workspace_repository) + "/**"
if external != {expected_workspace: "allow"}:
    raise SystemExit(f"unexpected workspace grant: {external}")

edit = data.get("permission", {}).get("edit", {})
for required in ("wp-admin/**", "wp-includes/**", "wp-content/plugins/**",
                 "wp-content/themes/**", "wp-content/mu-plugins/**", "wp-config.php"):
    if edit.get(required) != "deny":
        raise SystemExit(f"installed source not denied: {required} -> {edit.get(required)}")
if set(edit.values()) != {"deny"}:
    raise SystemExit(f"engineering must grant no edit allow: {edit}")
PY

if [ ! -f "$SITE_PATH/.opencode/plugins/claude-code-auth.ts" ]; then
  echo "FAIL: default Claude Code auth plugin was not installed"
  exit 1
fi
if [ -e "$KIMAKI_DATA_DIR/kimaki-config/plugins/homeboy-notification-context.ts" ]; then
  echo "FAIL: fresh config generation installed obsolete notification plugin"
  exit 1
fi

WITH_CLAUDE_CODE_AUTH=false
SITE_PATH="$TMP/site-without-auth"
mkdir -p "$SITE_PATH" "$KIMAKI_DATA_DIR"
UPDATED_ITEMS=()

runtime_generate_config

python3 - "$SITE_PATH/opencode.json" "$KIMAKI_DATA_DIR" "$SITE_PATH" <<'PY'
import json
import sys

opencode_json, kimaki_data_dir, site_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(opencode_json, encoding="utf-8") as handle:
    data = json.load(handle)

expected = [
    f"{kimaki_data_dir}/kimaki-config/plugins/dm-context-filter.ts",
    f"{kimaki_data_dir}/kimaki-config/plugins/dm-agent-sync.ts",
    f"{kimaki_data_dir}/kimaki-config/plugins/kimaki-session-attribution.ts",
]
actual = data.get("plugin")
if actual != expected:
    raise SystemExit(f"unexpected opt-out plugin paths: {actual}")

edit = data.get("permission", {}).get("edit", {})
for required in ("wp-admin/**", "wp-includes/**", "wp-content/plugins/**",
                 "wp-content/themes/**", "wp-content/mu-plugins/**", "wp-config.php"):
    if edit.get(required) != "deny":
        raise SystemExit(f"installed source not denied: {required} -> {edit.get(required)}")
if set(edit.values()) != {"deny"}:
    raise SystemExit(f"engineering must grant no edit allow: {edit}")
PY

if [ -f "$SITE_PATH/.opencode/plugins/claude-code-auth.ts" ]; then
  echo "FAIL: Claude Code auth plugin was installed despite opt-out"
  exit 1
fi

echo "PASS: tests/opencode-local-plugin-path.sh"
