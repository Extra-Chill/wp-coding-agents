#!/bin/bash
# Optional projection must preserve an upgrade's bounded outcome when a site
# has not registered its configured Data Machine agent with the Agents API.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/opencode-subagents.sh"

opencode_project_subagents() { return 1; }

# Selecting the WordPress agent/context alone never invokes graph projection.
AGENT_SLUG=coordinator
OPENCODE_AGENT_BUNDLE=""
opencode_project_subagents_optional
fixture=$(mktemp -d)
SITE_PATH="$fixture"
mkdir -p "$fixture/.opencode/agents"
printf '%s\n' 'existing specialist remains intact' > "$fixture/.opencode/agents/writer.md"
printf '%s\n' '{"sentinel":"wp-coding-agents-opencode-subagents-v2","agents":["agents/writer.md"],"artifacts":[],"general_agent":{"model":"legacy-chat-model"}}' > "$fixture/.opencode/.wp-coding-agents-subagents.json"
printf '%s\n' '{"agent":{"general":{"model":"legacy-chat-model"},"custom":{"model":"operator/model"}},"permission":{"task":{"general":"allow"}}}' > "$fixture/opencode.json"
opencode_project_subagents_optional
python3 - "$fixture" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
config=json.loads((root/'opencode.json').read_text())
assert config['agent']=={'custom':{'model':'operator/model'}}
assert config['permission']['task']=={'general':'allow'}
assert (root/'.opencode/agents/writer.md').read_text().strip()=='existing specialist remains intact'
manifest=root/'.opencode/.wp-coding-agents-subagents.json'
data=json.loads(manifest.read_text()); data['general_agent']={'model':'legacy-chat-model'}; manifest.write_text(json.dumps(data))
config['agent']['general']={'model':'operator/new-model'}; (root/'opencode.json').write_text(json.dumps(config))
PY
opencode_project_subagents_optional
python3 - "$fixture/opencode.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['agent']['general']['model']=='operator/new-model'
PY
rm -rf "$fixture"
unset SITE_PATH
OPENCODE_AGENT_BUNDLE=coordinator

PENDING_ITEMS=()
OPENCODE_SUBAGENT_PROJECTION_FAILURE=unregistered_coordinator
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
if ! opencode_project_subagents_optional > "$output" 2>&1; then
  echo "FAIL: optional OpenCode projection propagated its failure"
  exit 1
fi

case "$(<"$output")" in
  *"OpenCode subagent projection is pending"*) ;;
  *) echo "FAIL: optional projection did not report the pending recovery"; exit 1 ;;
esac

if [ "${#PENDING_ITEMS[@]}" -ne 1 ] || [ "${PENDING_ITEMS[0]}" != "OpenCode subagent projection (configured coordinator is not registered)" ]; then
  echo "FAIL: optional projection did not record its bounded pending state"
  exit 1
fi

for failure in missing_reader missing_projector wp_cli_read invalid_transport_response invalid_wp_cli_response projector; do
  PENDING_ITEMS=()
  OPENCODE_SUBAGENT_PROJECTION_FAILURE="$failure"
  if opencode_project_subagents_optional > "$output" 2>&1; then
    echo "FAIL: optional projection masked hard failure '$failure'"
    exit 1
  fi
  case "$(<"$output")" in
    *"projection failed ($failure)"*) ;;
    *) echo "FAIL: optional projection did not identify hard failure '$failure'"; exit 1 ;;
  esac
  if [ "${#PENDING_ITEMS[@]}" -ne 0 ]; then
    echo "FAIL: hard failure '$failure' was recorded as pending"
    exit 1
  fi
done

grep -qF 'opencode_project_subagents_optional' "$SCRIPT_DIR/upgrade.sh" || {
  echo "FAIL: upgrade does not use the optional projection boundary"
  exit 1
}
grep -qF 'warn "Pending:"' "$SCRIPT_DIR/upgrade.sh" || {
  echo "FAIL: upgrade summary does not report pending work"
  exit 1
}
grep -qF '_print_bridge_restart_hint' "$SCRIPT_DIR/upgrade.sh" || {
  echo "FAIL: upgrade summary does not retain bridge restart guidance"
  exit 1
}

echo "OK: optional OpenCode subagent projection preserves bounded recovery"
