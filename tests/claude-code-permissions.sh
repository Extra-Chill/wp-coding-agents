#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SITE_PATH="$TMP/site"
export DM_WORKSPACE_DIR="$TMP/workspace"
export AGENT_SLUG="builder"
export DRY_RUN=false
export IS_STUDIO=false
mkdir -p "$SITE_PATH/.claude" "$DM_WORKSPACE_DIR"

cat > "$SITE_PATH/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "deny": [
      "Read(./private/**)",
      "Edit(/wp-content/plugins/**)",
      "Edit(/wp-content/themes/**)",
      "Edit(/wp-includes/**)"
    ]
  }
}
JSON

UPDATED_ITEMS=()
log() { :; }
warn() { printf '%s\n' "$*" >&2; }

source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
POSTURE="${POSTURE:-engineering}"
source "$SCRIPT_DIR/runtimes/claude-code.sh"

runtime_install_hooks

python3 - "$SITE_PATH/.claude/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

site_path = sys.argv[1].removesuffix("/.claude/settings.json")
expected = {
    f"Edit({site_path}/wp-content/plugins/**)",
    f"Edit({site_path}/wp-content/themes/**)",
    f"Edit({site_path}/wp-includes/**)",
}
denies = set(data.get("permissions", {}).get("deny", []))
if not expected <= denies:
    raise SystemExit(f"missing WordPress mutation denies: {sorted(expected - denies)}")
if any(rule.startswith("Edit(/wp-content/") for rule in denies):
    raise SystemExit(f"WordPress mutation denies must be project-anchored: {sorted(denies)}")
if "Read(./private/**)" not in denies:
    raise SystemExit(f"existing deny was not preserved: {sorted(denies)}")
PY

HASH_BEFORE=$(md5 -q "$SITE_PATH/.claude/settings.json" 2>/dev/null || md5sum "$SITE_PATH/.claude/settings.json" | cut -d' ' -f1)
runtime_install_hooks
HASH_AFTER=$(md5 -q "$SITE_PATH/.claude/settings.json" 2>/dev/null || md5sum "$SITE_PATH/.claude/settings.json" | cut -d' ' -f1)
[ "$HASH_BEFORE" = "$HASH_AFTER" ]

echo "PASS: Claude Code WordPress edit permissions"
