#!/bin/bash
# tests/opencode-local-plugin-path.sh — a Roadie install ships no OpenCode plugins.
#
# wp-coding-agents#718: the four OpenCode plugins the Roadie bridge used to
# install are retired in favor of Roadie-native primitives (wordpress-context
# memory, ROADIE_CHANNELS_CONFIG channels, ROADIE_SHELL_ENV attribution), and
# claude-code-auth registers nothing under Roadie. Fresh local config
# generation must therefore write no `plugin` array at all — even with the
# Claude Code auth opt-in enabled — and no plugin files.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
ROADIE_DATA_DIR="$TMP/roadie-data"
WORKSPACE_REPOSITORY="$TMP/workspace"
mkdir -p "$SITE_PATH" "$ROADIE_DATA_DIR" "$WORKSPACE_REPOSITORY"
git -C "$WORKSPACE_REPOSITORY" init -q

export SCRIPT_DIR
export SITE_PATH
export ROADIE_DATA_DIR
export CHAT_BRIDGE="roadie"
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
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/install-source.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
SOURCE_MODE="${SOURCE_MODE:-workspace}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtimes/opencode.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

RESOLVED_ROADIE_PLUGINS_DIR=/opt/roadie-config/plugins
[ "$(bridge_managed_plugins_dir)" = "$ROADIE_DATA_DIR/roadie-config/plugins" ] || {
  echo "FAIL: local plugin path depended on child-process bridge state"
  exit 1
}

runtime_generate_config

python3 - "$SITE_PATH/opencode.json" "$WORKSPACE_REPOSITORY" <<'PY'
import json
import os
import sys

opencode_json, workspace_repository = sys.argv[1:]
with open(opencode_json, encoding="utf-8") as handle:
    data = json.load(handle)

# A Roadie install ships no OpenCode plugins (#718): not the retired managed
# three, and not claude-code-auth even with the opt-in flag set.
if "plugin" in data:
    raise SystemExit(f"Roadie install grew an OpenCode plugin array: {data.get('plugin')}")

# Data Machine memory still reaches sessions through `instructions`.
if not data.get("instructions"):
    raise SystemExit("Roadie install dropped the Data Machine memory instructions")

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

if [ -e "$ROADIE_DATA_DIR/roadie-config/plugins" ] && [ -n "$(ls "$ROADIE_DATA_DIR/roadie-config/plugins" 2>/dev/null)" ]; then
  echo "FAIL: fresh config generation installed OpenCode plugin files: $(ls "$ROADIE_DATA_DIR/roadie-config/plugins")"
  exit 1
fi
if [ -e "$SITE_PATH/.opencode/plugins/claude-code-auth.ts" ]; then
  echo "FAIL: claude-code-auth was installed under Roadie (registers nothing there)"
  exit 1
fi
if [ -e "$ROADIE_DATA_DIR/roadie-config/plugins/homeboy-notification-context.ts" ]; then
  echo "FAIL: fresh config generation installed obsolete notification plugin"
  exit 1
fi

# Without the auth opt-in the result is identical: still no plugins.
WITH_CLAUDE_CODE_AUTH=false
SITE_PATH="$TMP/site-without-auth"
mkdir -p "$SITE_PATH" "$ROADIE_DATA_DIR"
UPDATED_ITEMS=()

runtime_generate_config

python3 - "$SITE_PATH/opencode.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

if "plugin" in data:
    raise SystemExit(f"Roadie opt-out install grew an OpenCode plugin array: {data.get('plugin')}")

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

# The claude-code-auth plugin stays a direct (non-Roadie) OpenCode install:
# with CHAT_BRIDGE=none the opt-in still installs it and wires the entry.
CHAT_BRIDGE="none"
WITH_CLAUDE_CODE_AUTH=true
SITE_PATH="$TMP/site-direct"
mkdir -p "$SITE_PATH"
UPDATED_ITEMS=()

runtime_generate_config

python3 - "$SITE_PATH/opencode.json" "$SITE_PATH" <<'PY'
import json
import os
import sys

opencode_json, site_path = sys.argv[1:]
with open(opencode_json, encoding="utf-8") as handle:
    data = json.load(handle)

expected = [os.path.join(site_path, ".opencode/plugins/claude-code-auth.ts")]
if data.get("plugin") != expected:
    raise SystemExit(f"direct install lost claude-code-auth: {data.get('plugin')}")
if "instructions" not in data:
    raise SystemExit("direct install dropped the Data Machine memory instructions")
PY

if [ ! -f "$SITE_PATH/.opencode/plugins/claude-code-auth.ts" ]; then
  echo "FAIL: direct OpenCode install did not install claude-code-auth"
  exit 1
fi

echo "PASS: tests/opencode-local-plugin-path.sh"
