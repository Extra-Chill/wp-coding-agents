#!/bin/bash
# External profile: no local WordPress tree, argv-safe transport, local projection.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RUNTIME_PROJECT_ROOT="$TMP/runtime root"
WORDPRESS_PATH="/remote/site root"
WORDPRESS_USER="agent user"
TRANSPORT="$TMP/control transport"
ARGS="$TMP/transport-args"
KIMAKI_ENV="$TMP/kimaki-env"
GRAPH="$TMP/remote-subagent-graph.json"

mkdir -p "$RUNTIME_PROJECT_ROOT"
python3 - "$GRAPH" <<'PY'
import base64, json, sys
encode = lambda value: base64.b64encode(value).decode()
artifact = lambda value: encode(value.encode())
graph = {
  "success": True, "coordinator": "coordinator", "source_mode": "embedded", "nodes": [
    {"slug":"coordinator", "description":"Routes work", "model":"", "subagents":["writer", "reviewer"],
     "sources":{"instructions":{"SOUL.md":artifact("# Coordinator\n")}, "skills":{"root/SKILL.md":artifact("---\nname: root-skill\n---\n")}, "references":{}},
     "tool_policy":{"default":"deny", "allow":["bash"]}, "skill_policy":{"paths":["root/SKILL.md"]}},
    {"slug":"writer", "description":"Writes safely", "model":"openai/gpt-5", "subagents":["reviewer"],
     "sources":{"instructions":{"SOUL.md":artifact("# Writer\n")}, "skills":{"writer/SKILL.md":artifact("---\nname: editorial\n---\n\nWrite exact prose.\n")}, "references":{"writer/context.bin":encode(b"reference\x00bytes")}},
     "tool_policy":{"default":"deny", "allow":["bash"]}, "skill_policy":{"paths":["writer/SKILL.md"]}},
    {"slug":"reviewer", "description":"Reviews safely", "model":"", "subagents":[],
     "sources":{"instructions":{"SOUL.md":artifact("# Reviewer\n")}, "skills":{"review/SKILL.md":artifact("---\nname: review\n---\n")}, "references":{}},
     "tool_policy":{"default":"deny", "allow":["webfetch"]}, "skill_policy":{"paths":["review/SKILL.md"]}}
  ]
}
json.dump(graph, open(sys.argv[1], "w"))
PY
cat > "$TRANSPORT" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >> "$WP_TEST_ARGS"
case "$3:$4" in
  core:is-installed) exit 0 ;;
  datamachine:memory)
    case "$5" in
      injectable-files) printf '%s\n' '[{"filename":"SITE.md","layer":"shared","priority":10,"path":"/remote/wp-content/uploads/datamachine-files/shared/SITE.md"},{"filename":"SOUL.md","layer":"agent","priority":20,"path":"/remote/wp-content/uploads/datamachine-files/agents/remote/SOUL.md"}]' ;;
      read)
        case "$6" in
          SITE.md) printf '%s\n' 'site context' ;;
          SOUL.md) printf '%s\n' 'agent context' ;;
          *) exit 7 ;;
        esac
        ;;
    esac
    ;;
  eval:*)
    [ "$#" -eq 6 ] && [ "$5" = "--user=$WORDPRESS_USER" ] && [ "$6" = "--path=$WORDPRESS_PATH" ] || {
      echo "wp eval received unsupported positional arguments" >&2
      exit 9
    }
    case "$4" in
      *"require base64_decode"*) echo "decoded PHP source was treated as a filename" >&2; exit 9 ;;
    esac
    printf '%s' "$4" | grep -F "\$args=array(base64_decode('" >/dev/null || { echo "wp eval did not initialize reader arguments" >&2; exit 9; }
    printf '%s' "$4" | grep -F "'),'embedded');eval('?>'.base64_decode('" >/dev/null || { echo "wp eval did not execute embedded source" >&2; exit 9; }
    python3 - "$WP_TEST_GRAPH" <<'PY'
import sys
sys.stdout.write(open(sys.argv[1]).read())
PY
    ;;
esac
SH
chmod +x "$TRANSPORT"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kimaki" <<'SH'
#!/bin/bash
printf '%s\n%s\n%s\n' "$EXTERNAL_WORDPRESS" "$WORDPRESS_PATH" "$WORDPRESS_USER" > "$WP_TEST_KIMAKI_ENV"
SH
chmod +x "$TMP/bin/kimaki"

export SCRIPT_DIR RUNTIME_PROJECT_ROOT WORDPRESS_PATH WORDPRESS_USER AGENT_SLUG=coordinator
export WP_TEST_ARGS="$ARGS"
export WP_TEST_KIMAKI_ENV="$KIMAKI_ENV"
export WP_TEST_GRAPH="$GRAPH"
export PATH="$TMP/bin:$PATH"
export WP_CONTROL_TRANSPORT_JSON="[\"$TRANSPORT\",\"--identity\",\"secret value with spaces\"]"
export EXTERNAL_WORDPRESS=true DRY_RUN=false LOCAL_MODE=true IS_STUDIO=false
export SITE_PATH="$RUNTIME_PROJECT_ROOT" CHAT_BRIDGE=kimaki KIMAKI_DATA_DIR="$RUNTIME_PROJECT_ROOT/.kimaki"
export OPENCODE_MODEL='' OPENCODE_SMALL_MODEL='' WITH_CLAUDE_CODE_AUTH=false RUNTIME=opencode
export SOURCE_MODE=workspace DM_WORKSPACE_DIR="$TMP/workspace"
UPDATED_ITEMS=()

log() { :; }
warn() { printf '%s\n' "$*" >&2; }
error() { printf '%s\n' "$*" >&2; return 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ai-gateway.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/external-wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/skills.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/opencode-subagents.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtimes/opencode.sh"
error() { printf '%s\n' "$*" >&2; return 1; }

external_wordpress_prepare_transport
external_wordpress_validate
external_wordpress_project_context
runtime_generate_config
WITH_AI_GATEWAY=true
OPENAI_BASE_URL='https://runtime-only.invalid/private-endpoint'
OPENAI_API_KEY='runtime-only-secret-value'
export WITH_AI_GATEWAY OPENAI_BASE_URL OPENAI_API_KEY
ai_gateway_configure_opencode
runtime_generate_instructions
DETECTED_RUNTIMES=(opencode)
INSTALL_SKILLS=true
install_skills
opencode_project_subagents

[ ! -e "$RUNTIME_PROJECT_ROOT/wp-config.php" ] || { echo "FAIL: test created a local WordPress tree"; exit 1; }
[ "$(cat "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/shared/SITE.md")" = "site context" ] || { echo "FAIL: site context not projected"; exit 1; }
[ "$(cat "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/agent/SOUL.md")" = "agent context" ] || { echo "FAIL: agent context not projected"; exit 1; }
[ -f "$RUNTIME_PROJECT_ROOT/.opencode/skills/upgrade-wp-coding-agents/SKILL.md" ] || { echo "FAIL: skills were not installed below runtime root"; exit 1; }
[ -f "$RUNTIME_PROJECT_ROOT/.kimaki/kimaki-config/plugins/dm-context-filter.ts" ] || { echo "FAIL: Kimaki config was not installed below runtime root"; exit 1; }
[ ! -e "$RUNTIME_PROJECT_ROOT/wp-content" ] || { echo "FAIL: WordPress-side files were written below runtime root"; exit 1; }
[ -L "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context" ] || { echo "FAIL: projected context is not atomically activated"; exit 1; }
[ -f "$RUNTIME_PROJECT_ROOT/.opencode/agents/writer.md" ] || { echo "FAIL: embedded writer was not projected"; exit 1; }
[ -f "$RUNTIME_PROJECT_ROOT/.opencode/agents/reviewer.md" ] || { echo "FAIL: embedded reviewer was not projected"; exit 1; }
[ -f "$RUNTIME_PROJECT_ROOT/.opencode/skills/editorial/SKILL.md" ] || { echo "FAIL: embedded skill was not projected"; exit 1; }
[ -f "$RUNTIME_PROJECT_ROOT/.opencode/skills/editorial/references/context.bin" ] || { echo "FAIL: embedded reference was not projected"; exit 1; }
grep -F -- 'WordPress control: `./.wp-coding-agents/bin/wp-control`' "$RUNTIME_PROJECT_ROOT/AGENTS.md" >/dev/null
if grep -F -- 'grep it as needed' "$RUNTIME_PROJECT_ROOT/AGENTS.md" >/dev/null; then
  echo "FAIL: external guidance claims installed source is mounted"
  exit 1
fi

python3 - "$RUNTIME_PROJECT_ROOT/opencode.json" "$RUNTIME_PROJECT_ROOT" <<'PY'
import json, sys
config, root = sys.argv[1:]
data = json.load(open(config))
expected = ["./.wp-coding-agents/context/shared/SITE.md", "./.wp-coding-agents/context/agent/SOUL.md"]
if data.get("instructions") != expected:
    raise SystemExit(f"projected instructions differ: {data.get('instructions')}")
for plugin in data.get("plugin", []):
    if not plugin.startswith(root + "/"):
        raise SystemExit(f"plugin escaped runtime root: {plugin}")
provider = data.get("provider", {}).get("wp-ai-gateway", {})
if provider.get("options", {}).get("baseURL") != "${OPENAI_BASE_URL}":
    raise SystemExit("gateway provider does not use the runtime base URL placeholder")
if provider.get("env") != ["OPENAI_API_KEY"]:
    raise SystemExit("gateway provider does not declare runtime API key input")
if data.get("model") != "wp-ai-gateway/site-default":
    raise SystemExit("gateway model is not the runtime default")
PY

python3 - "$RUNTIME_PROJECT_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
assert root.joinpath(".opencode/skills/editorial/references/context.bin").read_bytes() == b"reference\x00bytes"
manifest = json.loads(root.joinpath(".opencode/.wp-coding-agents-subagents.json").read_text())
assert manifest["agents"] == ["agents/reviewer.md", "agents/writer.md"]
config = json.loads(root.joinpath("opencode.json").read_text())
assert config["permission"]["task"] == {"*": "deny", "writer": "allow", "reviewer": "allow"}
writer = root.joinpath(".opencode/agents/writer.md").read_text()
assert '"task":{"*":"deny","reviewer":"allow"}' in writer
PY
grep -x 'eval' "$ARGS" >/dev/null || { echo "FAIL: external graph reader did not use wp eval"; exit 1; }

while IFS= read -r argument; do
  case "$argument" in
    "--path=$WORDPRESS_PATH"|"--user=$WORDPRESS_USER"|"secret value with spaces") ;;
  esac
done < "$ARGS"
grep -F -- "--path=$WORDPRESS_PATH" "$ARGS" >/dev/null
grep -F -- "--user=$WORDPRESS_USER" "$ARGS" >/dev/null
grep -F -- "secret value with spaces" "$ARGS" >/dev/null

before_wrapper_calls="$(wc -l < "$ARGS" | tr -d ' ')"
unset WORDPRESS_PATH WORDPRESS_USER
"$RUNTIME_PROJECT_ROOT/.wp-coding-agents/bin/wp-control" option get siteurl >/dev/null
after_wrapper_calls="$(wc -l < "$ARGS" | tr -d ' ')"
[ "$after_wrapper_calls" -gt "$before_wrapper_calls" ] || { echo "FAIL: runtime control wrapper did not execute transport"; exit 1; }
"$RUNTIME_PROJECT_ROOT/.wp-coding-agents/bin/kimaki"
[ "$(sed -n '1p' "$KIMAKI_ENV")" = true ] || { echo "FAIL: Kimaki launcher did not set external profile"; exit 1; }
[ "$(sed -n '2p' "$KIMAKI_ENV")" = "/remote/site root" ] || { echo "FAIL: Kimaki launcher lost WordPress path"; exit 1; }
[ "$(sed -n '3p' "$KIMAKI_ENV")" = "agent user" ] || { echo "FAIL: Kimaki launcher lost WordPress user"; exit 1; }
export WORDPRESS_PATH="/remote/site root" WORDPRESS_USER="agent user"

if grep -R -F -- "secret value with spaces" "$RUNTIME_PROJECT_ROOT" >/dev/null 2>&1; then
  echo "FAIL: transport credential persisted below runtime root"
  exit 1
fi
if grep -R -E -- 'runtime-only\.invalid|runtime-only-secret-value' "$RUNTIME_PROJECT_ROOT" >/dev/null 2>&1; then
  echo "FAIL: runtime gateway credentials persisted below runtime root"
  exit 1
fi
[ ! -e "$RUNTIME_PROJECT_ROOT/.wp-coding-agents-subagent-graph.json" ] || { echo "FAIL: graph payload persisted below runtime root"; exit 1; }
if grep -R -F -- '/remote/wp-content/uploads/datamachine-files' "$RUNTIME_PROJECT_ROOT" >/dev/null 2>&1; then
  echo "FAIL: remote artifact paths persisted below runtime root"
  exit 1
fi
[ ! -e "$RUNTIME_PROJECT_ROOT/.opencode/wp-ai-gateway.env" ] || { echo "FAIL: external profile wrote a gateway env file"; exit 1; }

before_subagents="$(cksum "$RUNTIME_PROJECT_ROOT/.opencode/agents/writer.md" "$RUNTIME_PROJECT_ROOT/.opencode/.wp-coding-agents-subagents.json")"
opencode_project_subagents
after_subagents="$(cksum "$RUNTIME_PROJECT_ROOT/.opencode/agents/writer.md" "$RUNTIME_PROJECT_ROOT/.opencode/.wp-coding-agents-subagents.json")"
[ "$before_subagents" = "$after_subagents" ] || { echo "FAIL: embedded subagent projection is not byte-stable"; exit 1; }
python3 - "$GRAPH" <<'PY'
import json, sys
path = sys.argv[1]
graph = json.load(open(path))
graph["nodes"] = [node for node in graph["nodes"] if node["slug"] != "reviewer"]
graph["nodes"][0]["subagents"] = ["writer"]
graph["nodes"][1]["subagents"] = []
json.dump(graph, open(path, "w"))
PY
opencode_project_subagents
[ ! -e "$RUNTIME_PROJECT_ROOT/.opencode/agents/reviewer.md" ] || { echo "FAIL: stale embedded child survived"; exit 1; }
python3 - "$GRAPH" <<'PY'
import json, sys
path = sys.argv[1]
graph = json.load(open(path))
graph["nodes"][1]["sources"]["instructions"] = {"../escape.md": "aGVsbG8="}
json.dump(graph, open(path, "w"))
PY
if opencode_project_subagents; then echo "FAIL: traversal graph projected"; exit 1; fi
printf 'human configuration\n' > "$RUNTIME_PROJECT_ROOT/.opencode/agents/reviewer.md"
python3 - "$GRAPH" <<'PY'
import base64, json, sys
path = sys.argv[1]
graph = json.load(open(path))
graph["nodes"][1]["sources"]["instructions"] = {"SOUL.md": base64.b64encode(b"# Writer\n").decode()}
graph["nodes"].append({"slug":"reviewer", "description":"Reviewer", "model":"", "subagents":[], "sources":{"instructions":{"SOUL.md":base64.b64encode(b"# Reviewer\n").decode()}, "skills":{}, "references":{}}, "tool_policy":{}, "skill_policy":{"paths":[]}})
graph["nodes"][0]["subagents"] = ["writer", "reviewer"]
json.dump(graph, open(path, "w"))
PY
if opencode_project_subagents; then echo "FAIL: user-owned collision projected"; exit 1; fi
[ "$(<"$RUNTIME_PROJECT_ROOT/.opencode/agents/reviewer.md")" = 'human configuration' ] || { echo "FAIL: collision changed user file"; exit 1; }
printf '%s\n' '{"success":true,"coordinator":"coordinator","source_mode":"embedded","nodes":[{"slug":"bad_slug"}]}' > "$GRAPH"
if opencode_project_subagents; then echo "FAIL: malformed graph projected"; exit 1; fi

mkdir -p "$TMP/outside"
printf 'outside-safe\n' > "$TMP/outside/SOUL.md"
printf 'stale\n' > "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/stale.md"
rm -rf "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/agent"
ln -s "$TMP/outside" "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/agent"
external_wordpress_project_context
[ ! -e "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/stale.md" ] || { echo "FAIL: stale projected context survived rerun"; exit 1; }
[ ! -L "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context/agent" ] || { echo "FAIL: projected context retained a redirecting symlink"; exit 1; }
[ "$(cat "$TMP/outside/SOUL.md")" = "outside-safe" ] || { echo "FAIL: projected context followed a symlink outside its root"; exit 1; }

external_wordpress_project_context &
projection_one=$!
external_wordpress_project_context &
projection_two=$!
wait "$projection_one"
wait "$projection_two"
[ -d "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context" ] || { echo "FAIL: concurrent projection left a dangling context link"; exit 1; }
generation_count=$(python3 - "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context-generations" <<'PY'
import os, sys
print(sum(1 for entry in os.scandir(sys.argv[1]) if entry.is_dir(follow_symlinks=False)))
PY
)
[ "$generation_count" = 1 ] || { echo "FAIL: concurrent projection retained $generation_count generations"; exit 1; }

saved_transport_json="$WP_CONTROL_TRANSPORT_JSON"
WP_CONTROL_TRANSPORT_JSON='["/bin/true","line\nbreak"]'
external_wordpress_prepare_transport
[ "${WP_CONTROL_TRANSPORT[1]}" = $'line\nbreak' ] || { echo "FAIL: transport argv newline was split"; exit 1; }
WP_CONTROL_TRANSPORT_JSON="$saved_transport_json"
external_wordpress_prepare_transport

before="$(cksum "$RUNTIME_PROJECT_ROOT/opencode.json" "$RUNTIME_PROJECT_ROOT/AGENTS.md")"
external_wordpress_project_context
runtime_generate_config
ai_gateway_configure_opencode
runtime_generate_instructions
after="$(cksum "$RUNTIME_PROJECT_ROOT/opencode.json" "$RUNTIME_PROJECT_ROOT/AGENTS.md")"
[ "$before" = "$after" ] || { echo "FAIL: external profile is not idempotent"; exit 1; }

WP_CONTROL_TRANSPORT_JSON='["/does/not/exist"]'
external_wordpress_prepare_transport
if external_wordpress_validate; then
  echo "FAIL: unavailable transport validated"
  exit 1
fi

echo "PASS: tests/external-wordpress-runtime.sh"
