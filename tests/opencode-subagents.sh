#!/bin/bash
# Contract coverage for Data Machine coordinator graph -> OpenCode projection.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE_PATH="$TMP/site"
AGENT_SLUG="coordinator"
DRY_RUN=false
RUNTIME=opencode
mkdir -p "$SITE_PATH/.opencode/agents" "$TMP/identity"
touch "$SITE_PATH/wp-config.php"
printf '%s\n' '{"model":"preserve","mcp":{},"permission":{"read":"allow","skill":{"user-skill":"ask"}}}' > "$SITE_PATH/opencode.json"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/opencode-subagents.sh"
log() { :; }
warn() { printf '%s\n' "$*" >&2; }

FAILED=0
assert() { if "$@"; then printf '  ok   %s\n' "$*"; else printf '  FAIL %s\n' "$*"; FAILED=$((FAILED + 1)); fi; }
assert_python() { local name="$1"; shift; if python3 - "$@"; then printf '  ok   %s\n' "$name"; else printf '  FAIL %s\n' "$name"; FAILED=$((FAILED + 1)); fi; }
wp_cmd() { [ "$1" = eval-file ] && [ "$2" = "$SCRIPT_DIR/lib/read-opencode-subagent-graph.php" ] && [ "$3" = -- ] && [ "$4" = "$AGENT_SLUG" ]; cat "$TMP/graph.json"; }

php "$SCRIPT_DIR/tests/opencode-subagents-reader.php"
php "$SCRIPT_DIR/tests/opencode-subagents-reader.php" --embedded
php "$SCRIPT_DIR/tests/opencode-subagents-reader.php" --embedded outside
php "$SCRIPT_DIR/tests/opencode-subagents-reader.php" --embedded oversize
php "$SCRIPT_DIR/tests/opencode-subagents-reader.php" --embedded graph-limit

printf '# Writer identity\n\nWrite exact prose.\n' > "$TMP/identity/writer-soul.md"
mkdir -p "$TMP/identity-review"
printf '# Reviewer identity\n\nReport defects.\n' > "$TMP/identity-review/reviewer-soul.md"
printf '# Researcher identity\n\nGather evidence.\n' > "$TMP/identity/researcher-soul.md"
mkdir -p "$TMP/identity/skills/writer" "$TMP/identity/references/writer" "$TMP/identity-review/skills/reviewer" "$TMP/coordinator/skills/root" "$TMP/coordinator/references/root"
printf '# Coordinator identity\n' > "$TMP/coordinator/SOUL.md"
printf '%s\n' '---' 'name: editorial' '---' '' 'Follow the house style.' > "$TMP/identity/skills/writer/SKILL.md"
printf 'Reference bytes\n\x00\xff' > "$TMP/identity/references/writer/context.bin"
printf '%s\n' '---' 'name: review' '---' '' 'Use the review checklist.' > "$TMP/identity-review/skills/reviewer/SKILL.md"
printf '%s\n' '---' 'name: root-skill' '---' '' 'Use root context.' > "$TMP/coordinator/skills/root/SKILL.md"
printf 'Root reference bytes\n' > "$TMP/coordinator/references/root/context.md"

write_graph() {
  cat > "$TMP/graph.json" <<JSON
{
  "success": true,
  "coordinator": "coordinator",
  "nodes": [
    {"slug":"coordinator","label":"Coordinator","description":"Routes work","subagents":["writer","reviewer","researcher"],"model":"","sources":{"instructions":{"SOUL.md":"$TMP/coordinator/SOUL.md"},"skills":{"root/SKILL.md":"$TMP/coordinator/skills/root/SKILL.md"},"references":{"root/context.md":"$TMP/coordinator/references/root/context.md"}},"tool_policy":{"default":"deny","allow":["datamachine/search","websearch"]},"skill_policy":{"paths":["root/SKILL.md"]}},
    {"slug":"writer","label":"Writer","description":"Write implementation","subagents":["researcher"],"model":"openai/gpt-5","sources":{"instructions":{"SOUL.md":"$TMP/identity/writer-soul.md"},"skills":{"writer/SKILL.md":"$TMP/identity/skills/writer/SKILL.md"},"references":{"writer/context.bin":"$TMP/identity/references/writer/context.bin"}},"tool_policy":{"default":"deny","allow":["datamachine/search","bash"]},"skill_policy":{"paths":["writer/SKILL.md"]}},
    {"slug":"reviewer","label":"Reviewer","description":"Review implementation","subagents":[],"model":"","sources":{"instructions":{"SOUL.md":"$TMP/identity-review/reviewer-soul.md"},"skills":{"reviewer/SKILL.md":"$TMP/identity-review/skills/reviewer/SKILL.md"},"references":{}},"tool_policy":{"default":"deny","allow":["datamachine/search"]},"skill_policy":{"paths":["reviewer/SKILL.md"]}},
    {"slug":"researcher","label":"Researcher","description":"Research context","subagents":[],"model":"","sources":{"instructions":{"SOUL.md":"$TMP/identity/researcher-soul.md"},"skills":{},"references":{}},"tool_policy":{"default":"deny","allow":["webfetch"]},"skill_policy":{"paths":[]}}
  ]
}
JSON
}

write_graph
echo '==> coordinator plus three graph children'
opencode_project_subagents
assert test -f "$SITE_PATH/.opencode/agents/writer.md"
assert test -f "$SITE_PATH/.opencode/agents/reviewer.md"
assert test -f "$SITE_PATH/.opencode/agents/researcher.md"
assert_python 'model, policy, skill allowlist, and child identity project' "$SITE_PATH/.opencode/agents/writer.md" <<'PY'
import sys
text = open(sys.argv[1]).read()
assert 'description: "Write implementation"' in text
assert 'mode: subagent' in text
assert 'model: "openai/gpt-5"' in text
assert '"*":"deny"' in text and '"bash":"allow"' in text
assert 'datamachine/search' not in text
assert '"skill":{"editorial":"allow"}' in text
assert '"task":{"*":"deny","researcher":"allow"}' in text
assert 'skills:' not in text
assert '# Writer identity\n\nWrite exact prose.' in text
PY
assert_python 'source maps retain bytes and scope references to owning skill' "$TMP/identity/skills/writer/SKILL.md" "$SITE_PATH/.opencode/skills/editorial/SKILL.md" "$TMP/identity/references/writer/context.bin" "$SITE_PATH/.opencode/skills/editorial/references/context.bin" <<'PY'
import sys
# Mapping contract: each child owns one OpenCode skill directory. Source-map
# paths stay below its skills/ or references/ branch, so matching basenames
# never collide and every graph key remains recoverable from the destination.
assert open(sys.argv[1], 'rb').read() == open(sys.argv[2], 'rb').read()
assert open(sys.argv[3], 'rb').read() == open(sys.argv[4], 'rb').read()
PY
assert_python 'manifest records only managed files and task is limited to direct children' "$SITE_PATH/.opencode/.wp-coding-agents-subagents.json" "$SITE_PATH/opencode.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
assert manifest['agents'] == ['agents/researcher.md', 'agents/reviewer.md', 'agents/writer.md']
assert 'skills/editorial/SKILL.md' in manifest['artifacts']
assert 'skills/editorial/references/context.bin' in manifest['artifacts']
config = json.load(open(sys.argv[2]))
assert config['model'] == 'preserve' and config['mcp'] == {}
assert config['permission']['read'] == 'allow'
assert config['permission']['task'] == {'*': 'deny', 'researcher': 'allow', 'reviewer': 'allow', 'writer': 'allow'}
assert config['permission']['skill']['root-skill'] == 'allow'
assert config['permission']['skill']['user-skill'] == 'ask'
assert open(sys.argv[1].replace('.wp-coding-agents-subagents.json', 'skills/root-skill/SKILL.md'), 'rb').read().startswith(b'---\nname: root-skill\n')
PY
if command -v opencode >/dev/null 2>&1; then
  (cd "$SITE_PATH" && opencode agent list --pure >/dev/null)
  printf '  ok   OpenCode parses generated agent and skill files\n'
fi

echo '==> idempotency and stale managed removal'
before="$(shasum "$SITE_PATH/.opencode/agents/writer.md" "$SITE_PATH/.opencode/.wp-coding-agents-subagents.json")"
opencode_project_subagents
after="$(shasum "$SITE_PATH/.opencode/agents/writer.md" "$SITE_PATH/.opencode/.wp-coding-agents-subagents.json")"
[ "$before" = "$after" ] || FAILED=$((FAILED + 1))
printf '  ok   repeated graph reconciliation is byte-stable\n'
python3 - "$TMP/graph.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data['nodes'] = [node for node in data['nodes'] if node['slug'] in ('coordinator', 'writer')]
data['nodes'][0]['subagents'] = ['writer']
data['nodes'][1]['subagents'] = []
data['nodes'][0]['sources']['skills'] = {}
data['nodes'][0]['sources']['references'] = {}
data['nodes'][0]['skill_policy']['paths'] = []
json.dump(data, open(p, 'w'))
PY
opencode_project_subagents
assert test ! -e "$SITE_PATH/.opencode/agents/reviewer.md"
assert test ! -e "$SITE_PATH/.opencode/agents/researcher.md"
assert test ! -e "$SITE_PATH/.opencode/skills/review/SKILL.md"
assert test -f "$SITE_PATH/.opencode/agents/writer.md"

echo '==> malformed graph and user-owned collision reject without mutation'
before="$(shasum "$SITE_PATH/.opencode/agents/writer.md")"
printf '%s\n' '{"success":true,"coordinator":"coordinator","nodes":[{"slug":"bad_slug"}]}' > "$TMP/graph.json"
if opencode_project_subagents; then FAILED=$((FAILED + 1)); fi
after="$(shasum "$SITE_PATH/.opencode/agents/writer.md")"
[ "$before" = "$after" ] || FAILED=$((FAILED + 1))
printf '  ok   malformed graph leaves managed state unchanged\n'
rm "$SITE_PATH/.opencode/agents/writer.md"
printf '%s\n' 'human configuration' > "$SITE_PATH/.opencode/agents/writer.md"
write_graph
if opencode_project_subagents; then FAILED=$((FAILED + 1)); fi
assert_python 'user-owned collision remains intact' "$SITE_PATH/.opencode/agents/writer.md" <<'PY'
import sys
assert open(sys.argv[1]).read() == 'human configuration\n'
PY

rm "$SITE_PATH/.opencode/agents/writer.md"
write_graph
python3 - "$TMP/graph.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data['nodes'].append({
    'slug': 'collision', 'label': 'Collision', 'description': 'Collision',
    'subagents': [], 'model': '',
    'sources': {'instructions': {'SOUL.md': data['nodes'][1]['sources']['instructions']['SOUL.md']}, 'skills': {}, 'references': {}},
    'tool_policy': {'opencode': {'permission': {}}}, 'skill_policy': {'paths': []},
})
data['nodes'][0]['subagents'].append('collision')
json.dump(data, open(p, 'w'))
PY
printf '%s\n' 'user-owned agent' > "$SITE_PATH/.opencode/agents/collision.md"
if opencode_project_subagents; then FAILED=$((FAILED + 1)); fi
assert_python 'unmanaged agent collision remains intact' "$SITE_PATH/.opencode/agents/collision.md" <<'PY'
import sys
assert open(sys.argv[1]).read() == 'user-owned agent\n'
PY

echo '==> containment and nested child policies reject unsafe input'
write_graph
before="$(shasum "$SITE_PATH/.opencode/.wp-coding-agents-subagents.json")"
python3 - "$SITE_PATH/.opencode/.wp-coding-agents-subagents.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data['artifacts'] = ['../outside']
json.dump(data, open(p, 'w'))
PY
if opencode_project_subagents; then FAILED=$((FAILED + 1)); fi
printf '%s\n' '  ok   manifest traversal is rejected'
rm "$SITE_PATH/.opencode/.wp-coding-agents-subagents.json"
write_graph
ln -s "$TMP/identity/writer-soul.md" "$TMP/identity/skills/writer/link.md"
python3 - "$TMP/graph.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data['nodes'][1]['sources']['skills']['writer/link.md'] = data['nodes'][1]['sources']['skills']['writer/SKILL.md'].replace('SKILL.md', 'link.md')
data['nodes'][1]['skill_policy']['paths'].append('writer/link.md')
json.dump(data, open(p, 'w'))
PY
if opencode_project_subagents; then FAILED=$((FAILED + 1)); fi
printf '%s\n' '  ok   symlink source is rejected'

write_graph
python3 - "$TMP/graph.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
# The coordinator name collides with the writer's frontmatter name. This must
# reject the complete graph before it can overwrite any generated artifact.
root = data['nodes'][0]['sources']['skills']['root/SKILL.md']
open(root, 'w').write('---\nname: editorial\n---\n')
data['nodes'][0]['skill_policy']['paths'] = ['root/SKILL.md']
json.dump(data, open(p, 'w'))
PY
if opencode_project_subagents; then FAILED=$((FAILED + 1)); fi
printf '%s\n' '  ok   graph-wide duplicate skill name is rejected'

[ "$FAILED" -eq 0 ] || exit 1
