#!/bin/bash
# tests/repair-opencode-json.sh — regression tests for opencode.json repair.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPAIR="$SCRIPT_DIR/lib/repair-opencode-json.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_json_missing_agent_slots() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

agent = data.get("agent", {})
if "build" in agent or "plan" in agent:
    raise SystemExit(f"managed build/plan slots should be removed: {agent}")
PY
}

cat > "$TMP/default-only.json" <<'JSON'
{
  "model": "anthropic/claude-opus-4-7",
  "agent": {
    "build": { "mode": "primary", "model": "anthropic/claude-opus-4-7" },
    "plan": { "mode": "primary", "model": "anthropic/claude-opus-4-7" }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/default-only.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/default-only.out"

assert_json_missing_agent_slots "$TMP/default-only.json"
grep -q '"agent_cleanup": "removed"' "$TMP/default-only.out"

cat > "$TMP/prompt-migration.json" <<'JSON'
{
  "model": "anthropic/claude-opus-4-7",
  "agent": {
    "build": {
      "mode": "primary",
      "model": "anthropic/claude-opus-4-7",
      "prompt": "{file:./AGENTS.md}\n{file:./SOUL.md}\n{file:./MEMORY.md}"
    },
    "plan": {
      "mode": "primary",
      "model": "anthropic/claude-opus-4-7",
      "prompt": "{file:./AGENTS.md}\n{file:./SOUL.md}"
    }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/prompt-migration.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/prompt-migration.out"

assert_json_missing_agent_slots "$TMP/prompt-migration.json"
python3 - "$TMP/prompt-migration.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

if data.get("instructions") != ["./SOUL.md", "./MEMORY.md"]:
    raise SystemExit(f"unexpected instructions: {data.get('instructions')}")
PY

cat > "$TMP/custom-agent.json" <<'JSON'
{
  "model": "anthropic/claude-opus-4-7",
  "agent": {
    "build": { "mode": "primary", "tools": { "bash": true } },
    "plan": { "mode": "primary", "model": "openai/gpt-5.5" }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/custom-agent.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/custom-agent.out"

python3 - "$TMP/custom-agent.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

agent = data.get("agent", {})
if "build" not in agent or "plan" not in agent:
    raise SystemExit(f"custom build/plan slots should be preserved: {agent}")
PY

cat > "$TMP/local-plugin-path.json" <<'JSON'
{
  "plugin": [
    "/Users/example/.nvm/versions/node/v24/lib/node_modules/kimaki/plugins/dm-context-filter.ts",
    "/Users/example/.nvm/versions/node/v24/lib/node_modules/kimaki/plugins/dm-agent-sync.ts",
    "/Users/example/.nvm/versions/node/v24/lib/node_modules/kimaki/plugins/homeboy-notification-context.ts"
  ]
}
JSON

python3 "$REPAIR" \
  --file "$TMP/local-plugin-path.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /Users/example/.kimaki/kimaki-config/plugins \
  --additive > "$TMP/local-plugin-path.out"

python3 - "$TMP/local-plugin-path.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected = [
    "/Users/example/.kimaki/kimaki-config/plugins/dm-context-filter.ts",
    "/Users/example/.kimaki/kimaki-config/plugins/dm-agent-sync.ts",
]
if data.get("plugin") != expected:
    raise SystemExit(f"unexpected plugin paths: {data.get('plugin')}")
PY
grep -q '"status": "additive_repaired"' "$TMP/local-plugin-path.out"
grep -q '"rewritten"' "$TMP/local-plugin-path.out"

cat > "$TMP/managed-instructions.json" <<'JSON'
{
  "instructions": [
    "./wp-content/uploads/datamachine-files/shared/SITE.md",
    "./wp-content/uploads/datamachine-files/agents/old-agent/MEMORY.md",
    "./docs/custom.md"
  ]
}
JSON
cat > "$TMP/managed-instructions.txt" <<'EOF'
/srv/site/wp-content/uploads/datamachine-files/shared/SITE.md
/srv/site/wp-content/uploads/datamachine-files/agents/current-agent/MEMORY.md
/srv/site/wp-content/uploads/datamachine-files/users/1/USER.md
EOF

python3 "$REPAIR" \
  --file "$TMP/managed-instructions.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --managed-instructions-file "$TMP/managed-instructions.txt" \
  --additive > "$TMP/managed-instructions.out"

python3 - "$TMP/managed-instructions.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected = [
    "/srv/site/wp-content/uploads/datamachine-files/shared/SITE.md",
    "/srv/site/wp-content/uploads/datamachine-files/agents/current-agent/MEMORY.md",
    "/srv/site/wp-content/uploads/datamachine-files/users/1/USER.md",
    "./docs/custom.md",
]
if data.get("instructions") != expected:
    raise SystemExit(f"unexpected instructions: {data.get('instructions')}")
PY
grep -q '"instruction_sync": "synced"' "$TMP/managed-instructions.out"

cat > "$TMP/edit-permissions.json" <<'JSON'
{
  "permission": {
    "bash": "allow",
    "edit": {
      "*": "allow",
      "docs/**": "ask",
      "wp-includes/**": "allow"
    }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/edit-permissions.json" \
  --runtime opencode \
  --chat-bridge none \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/edit-permissions.out"

python3 - "$TMP/edit-permissions.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected = {
    "*": "allow",
    "docs/**": "ask",
    "wp-content/plugins/**": "deny",
    "wp-content/themes/**": "deny",
    "wp-includes/**": "deny",
}
permission = data.get("permission", {})
if permission.get("edit") != expected:
    raise SystemExit(f"unexpected managed edit rules: {permission.get('edit')}")
if permission.get("bash") != "allow":
    raise SystemExit(f"user bash permission was not preserved: {permission}")
PY
grep -q '"edit_permission": "synced"' "$TMP/edit-permissions.out"

cat > "$TMP/claude-code-auth-plugin.json" <<'JSON'
{
  "plugin": []
}
JSON

python3 "$REPAIR" \
  --file "$TMP/claude-code-auth-plugin.json" \
  --runtime opencode \
  --chat-bridge none \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --claude-code-auth-plugin /srv/site/.opencode/plugins/claude-code-auth.ts \
  --additive > "$TMP/claude-code-auth-plugin.out"

python3 - "$TMP/claude-code-auth-plugin.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected = ["/srv/site/.opencode/plugins/claude-code-auth.ts"]
if data.get("plugin") != expected:
    raise SystemExit(f"unexpected claude code auth plugin paths: {data.get('plugin')}")
PY
grep -q '"status": "additive_repaired"' "$TMP/claude-code-auth-plugin.out"

echo "OK: repair-opencode-json removes managed agent shells and repairs local plugin paths"
