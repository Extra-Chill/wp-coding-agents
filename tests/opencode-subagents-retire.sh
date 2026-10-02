#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$ROOT/lib/opencode-subagents-retire.sh"

new_site() {
  SITE="$TMP/$1"
  mkdir -p "$SITE/.opencode/agents" "$SITE/.opencode/skills/example"
  printf '{\n  "model": "openai/test",\n  "permission": {"task": {"*": "deny"}, "skill": {"example": "allow"}, "edit": {"*": "deny"}},\n  "agent": {"general": {"model": "openai/test"}}\n}\n' > "$SITE/opencode.json"
}
write_manifest() {
  python3 - "$SITE/.opencode/.wp-coding-agents-subagents.json" "$1" <<'PY'
import json, sys
json.dump({"sentinel": sys.argv[2], "artifacts": ["agents/worker.md", "skills/example/SKILL.md"],
           "task_permission": {"*": "deny"}, "skill_permission": {"example": "allow"},
           "general_agent": {"model": "openai/test"}}, open(sys.argv[1], "w"))
PY
  printf 'managed agent\n' > "$SITE/.opencode/agents/worker.md"
  printf 'managed skill\n' > "$SITE/.opencode/skills/example/SKILL.md"
}

new_site absent
before="$(cksum "$SITE/opencode.json")"
opencode_subagents_retire "$SITE"
[ "$before" = "$(cksum "$SITE/opencode.json")" ]

new_site clean
write_manifest wp-coding-agents-opencode-subagents-v2
opencode_subagents_retire "$SITE"
[ ! -e "$SITE/.opencode/.wp-coding-agents-subagents.json" ]
[ ! -e "$SITE/.opencode/agents/worker.md" ]
[ ! -e "$SITE/.opencode/skills/example/SKILL.md" ]
python3 - "$SITE/opencode.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["permission"] == {"edit": {"*": "deny"}}
assert "agent" not in d
PY

new_site operator
write_manifest wp-coding-agents-opencode-subagents-v2
python3 - "$SITE/opencode.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["agent"]["general"]["model"]="operator/custom"
json.dump(d, open(p,"w"), indent=2)
PY
opencode_subagents_retire "$SITE"
python3 - "$SITE/opencode.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["agent"]["general"]["model"] == "operator/custom"
assert d["permission"] == {"edit": {"*": "deny"}}
PY

new_site unknown
write_manifest another-tool-v1
before="$(cksum "$SITE/.opencode/.wp-coding-agents-subagents.json" "$SITE/.opencode/agents/worker.md")"
warning="$(opencode_subagents_retire "$SITE" 2>&1)"
case "$warning" in *"unrecognized manifest sentinel"*) ;; *) echo "FAIL: missing unknown-sentinel warning: $warning" >&2; exit 1 ;; esac
[ "$before" = "$(cksum "$SITE/.opencode/.wp-coding-agents-subagents.json" "$SITE/.opencode/agents/worker.md")" ]

echo "OK: OpenCode subagent retirement is bounded and preserves operator edits"
