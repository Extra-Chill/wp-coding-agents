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
  --chat-bridge roadie \
  --roadie-plugins-dir /opt/roadie-config/plugins \
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
  --chat-bridge roadie \
  --roadie-plugins-dir /opt/roadie-config/plugins \
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
  --chat-bridge roadie \
  --roadie-plugins-dir /opt/roadie-config/plugins \
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
    "/Users/example/.nvm/versions/node/v24/lib/node_modules/kimaki/plugins/kimaki-session-attribution.ts",
    "/Users/example/.nvm/versions/node/v24/lib/node_modules/kimaki/plugins/homeboy-notification-context.ts"
  ]
}
JSON

python3 "$REPAIR" \
  --file "$TMP/local-plugin-path.json" \
  --runtime opencode \
  --chat-bridge roadie \
  --roadie-plugins-dir /Users/example/.roadie/roadie-config/plugins \
  --additive > "$TMP/local-plugin-path.out"

python3 - "$TMP/local-plugin-path.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

# Kimaki-era entries: dm-agent-sync is rewritten into the Roadie config dir,
# the retired Kimaki plugins are dropped, and Roadie's new plugins are added.
expected = [
    "/Users/example/.roadie/roadie-config/plugins/dm-agent-sync.ts",
    "/Users/example/.roadie/roadie-config/plugins/roadie-command-guard.ts",
    "/Users/example/.roadie/roadie-config/plugins/session-attribution.ts",
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
  --chat-bridge roadie \
  --roadie-plugins-dir /opt/roadie-config/plugins \
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
  --roadie-plugins-dir /opt/roadie-config/plugins \
  --additive > "$TMP/edit-permissions.out"

python3 - "$TMP/edit-permissions.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

permission = data.get("permission", {})
edit = permission.get("edit", {})
# Operator rules survive, and they keep their position ahead of the managed
# block so the managed denies still win under findLast.
for pattern, action in (("*", "allow"), ("docs/**", "ask")):
    if edit.get(pattern) != action:
        raise SystemExit(f"operator rule lost: {pattern} -> {edit.get(pattern)}")
keys = list(edit)
if keys.index("docs/**") > keys.index("wp-admin/**"):
    raise SystemExit(f"operator rules must precede the managed block: {keys}")
for required in ("wp-admin/**", "wp-includes/**", "wp-content/plugins/**",
                 "wp-content/themes/**", "wp-content/mu-plugins/**", "wp-config.php"):
    if edit.get(required) != "deny":
        raise SystemExit(f"installed source not denied: {required} -> {edit.get(required)}")
if permission.get("bash") != "allow":
    raise SystemExit(f"user bash permission was not preserved: {permission}")
PY
grep -q '"edit_permission": "synced"' "$TMP/edit-permissions.out"

# Workspace mode permits exactly the explicitly opted-in wp-config.php file.
# Exercise diagnostic, additive/repeat-upgrade, apply, opt-out, and owned mode
# through the CLI; no site files are opened or modified by these fixtures.
cat > "$TMP/workspace-config-permission.json" <<'JSON'
{
  "permission": {
    "bash": "allow",
    "edit": { "*": "allow", "docs/**": "ask" }
  }
}
JSON

run_repair() {
  python3 "$REPAIR" \
    --file "$TMP/workspace-config-permission.json" \
    --runtime opencode \
    --chat-bridge none \
    --roadie-plugins-dir /opt/roadie-config/plugins \
    --source-mode workspace "$@"
}

if run_repair --owned-writable wp-config.php > "$TMP/workspace-config-diagnostic.out"; then
  echo "diagnostic should report permission drift" >&2
  exit 1
fi
grep -q '"edit_permission": "needed"' "$TMP/workspace-config-diagnostic.out"
run_repair --owned-writable wp-config.php --additive > "$TMP/workspace-config-additive.out"
python3 - "$TMP/workspace-config-permission.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
edit = data["permission"]["edit"]
if edit.get("wp-config.php") != "allow":
    raise SystemExit(f"explicit workspace wp-config allow missing: {edit}")
if edit.get("wp-admin/**") != "deny" or list(edit).index("wp-admin/**") > list(edit).index("wp-config.php"):
    raise SystemExit(f"managed deny must precede exception allow: {edit}")
if edit.get("wp-settings.php") != "deny" or edit.get("wp-includes/**") != "deny":
    raise SystemExit(f"other installed files were opened: {edit}")
if edit.get("*") != "allow" or edit.get("docs/**") != "ask" or data["permission"].get("bash") != "allow":
    raise SystemExit(f"user rules changed: {data}")
PY
run_repair --owned-writable wp-config.php --additive > "$TMP/workspace-config-repeat.out"
grep -q '"edit_permission": "ok"' "$TMP/workspace-config-repeat.out"
run_repair --owned-writable wp-config.php --apply > "$TMP/workspace-config-apply.out"
python3 - "$TMP/workspace-config-permission.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    edit = json.load(handle)["permission"]["edit"]
if edit.get("wp-config.php") != "allow" or edit.get("wp-settings.php") != "deny":
    raise SystemExit(f"apply produced incorrect workspace exception: {edit}")
PY

run_repair --additive > "$TMP/workspace-config-optout.out"
python3 - "$TMP/workspace-config-permission.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    edit = json.load(handle)["permission"]["edit"]
if edit.get("wp-config.php") != "deny" or edit.get("wp-settings.php") != "deny":
    raise SystemExit(f"opt-out did not close exact exception: {edit}")
PY

run_repair --source-mode owned --owned-writable wp-config.php --additive > "$TMP/owned-config.out"
python3 - "$TMP/workspace-config-permission.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    edit = json.load(handle)["permission"]["edit"]
if edit.get("wp-config.php") != "allow":
    raise SystemExit(f"owned writable regression: {edit}")
PY

cat > "$TMP/default-config-permission.json" <<'JSON'
{"permission":{"edit":{"wp-settings.php":"allow"}}}
JSON
python3 "$REPAIR" --file "$TMP/default-config-permission.json" --runtime opencode --chat-bridge none --additive > "$TMP/default-config.out"
python3 - "$TMP/default-config-permission.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    edit = json.load(handle)["permission"]["edit"]
if edit.get("wp-config.php") != "deny":
    raise SystemExit(f"default must remain denied: {edit}")
PY

cat > "$TMP/workspace-permission.json" <<'JSON'
{
  "permission": {
    "external_directory": {
      "/Users/example/.datamachine/workspace/**": "allow"
    }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/workspace-permission.json" \
  --runtime opencode \
  --chat-bridge none \
  --roadie-plugins-dir /opt/roadie-config/plugins \
  --workspace-dir /Users/example/Developer \
  --workspace-dir /Users/example/Studio \
  --additive > "$TMP/workspace-permission.out"

python3 - "$TMP/workspace-permission.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

external = data.get("permission", {}).get("external_directory", {})
expected = {
    "/Users/example/Developer/**": "allow",
    "/Users/example/Studio/**": "allow",
}
if external != expected:
    raise SystemExit(f"stale workspace grant was not replaced: {external}")
PY
grep -q '"external_directory": "synced"' "$TMP/workspace-permission.out"

cat > "$TMP/claude-code-auth-plugin.json" <<'JSON'
{
  "plugin": []
}
JSON

python3 "$REPAIR" \
  --file "$TMP/claude-code-auth-plugin.json" \
  --runtime opencode \
  --chat-bridge none \
  --roadie-plugins-dir /opt/roadie-config/plugins \
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

# --- subrouter/<preset> -> roadie/<preset> (#709) --------------------------
# The plugin array is already managed so the only drift is the model route.
ROADIE_PLUGINS='["/opt/roadie-config/plugins/dm-agent-sync.ts", "/opt/roadie-config/plugins/roadie-command-guard.ts", "/opt/roadie-config/plugins/session-attribution.ts"]'
mkdir -p "$TMP/roadie-data/credentials/shared"
ROTATIONS="$TMP/roadie-data/credentials/shared/rotation.json"
printf '{"anthropic-claude-opus-5-5":["anthropic/claude-opus-5-5"],"opus":["anthropic/claude-opus-5-5"]}\n' > "$ROTATIONS"

write_route_fixture() {
  cat > "$1" <<JSON
{
  "model": "subrouter/opus",
  "small_model": "subrouter/anthropic-claude-haiku-5-5",
  "plugin": $ROADIE_PLUGINS
}
JSON
}

route() {
  python3 "$REPAIR" --file "$1" --runtime opencode --chat-bridge roadie \
    --roadie-plugins-dir /opt/roadie-config/plugins \
    --roadie-rotations-file "$ROTATIONS" "${@:2}"
}

model_pair() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["model"], d["small_model"])' "$1"
}

# Diagnostic run (what upgrade --dry-run shows): reports, never writes.
write_route_fixture "$TMP/route.json"
cp "$TMP/route.json" "$TMP/route.orig.json"
set +e
route "$TMP/route.json" > "$TMP/route-dry.out"
dry_rc=$?
set -e
[ "$dry_rc" -eq 1 ] || { echo "FAIL: diagnostic should report drift (rc=$dry_rc)"; exit 1; }
grep -q '"model_route": "needed"' "$TMP/route-dry.out" || { echo "FAIL: diagnostic does not report the model route"; cat "$TMP/route-dry.out"; exit 1; }
grep -q '"to": "roadie/opus"' "$TMP/route-dry.out" || { echo "FAIL: diagnostic does not show the planned rewrite"; exit 1; }
cmp -s "$TMP/route.json" "$TMP/route.orig.json" || { echo "FAIL: diagnostic wrote opencode.json"; exit 1; }

# Additive repair: a preset that is a pool rotation moves; one that is not
# stays, because Roadie still serves subrouter/<preset> from its pool alias.
route "$TMP/route.json" --additive --backup-dir "$TMP/route-backups" > "$TMP/route-apply.out"
[ "$(model_pair "$TMP/route.json")" = "roadie/opus subrouter/anthropic-claude-haiku-5-5" ] \
  || { echo "FAIL: model route rewrite: $(model_pair "$TMP/route.json")"; exit 1; }
grep -q '"model_route": "rewritten"' "$TMP/route-apply.out" || { echo "FAIL: write result lacks model_route"; cat "$TMP/route-apply.out"; exit 1; }
ls "$TMP/route-backups"/route.json.backup.* >/dev/null 2>&1 || { echo "FAIL: no backup written before the rewrite"; exit 1; }
cmp -s "$(ls "$TMP/route-backups"/route.json.backup.* | head -1)" "$TMP/route.orig.json" || { echo "FAIL: backup is not the pre-rewrite file"; exit 1; }

# Idempotent: the second run has nothing to do.
cp "$TMP/route.json" "$TMP/route.after.json"
route "$TMP/route.json" --additive > "$TMP/route-again.out"
grep -q '"model_route": "ok"' "$TMP/route-again.out" || { echo "FAIL: second run is not a no-op"; cat "$TMP/route-again.out"; exit 1; }
cmp -s "$TMP/route.json" "$TMP/route.after.json" || { echo "FAIL: second run changed opencode.json"; exit 1; }

# No rotation file (pool not created yet) or a non-Roadie bridge: untouched.
write_route_fixture "$TMP/route-nopool.json"
python3 "$REPAIR" --file "$TMP/route-nopool.json" --runtime opencode --chat-bridge roadie \
  --roadie-plugins-dir /opt/roadie-config/plugins \
  --roadie-rotations-file "$TMP/missing/rotation.json" --additive > /dev/null
[ "$(model_pair "$TMP/route-nopool.json")" = "subrouter/opus subrouter/anthropic-claude-haiku-5-5" ] \
  || { echo "FAIL: rewrote without a rotation file"; exit 1; }

echo "OK: repair-opencode-json moves subrouter/<preset> to existing roadie rotations"

echo "OK: repair-opencode-json removes managed agent shells and repairs local plugin paths"
