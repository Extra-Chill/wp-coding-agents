#!/bin/bash
# Optional projection must preserve an upgrade's bounded outcome when a site
# has not registered its configured Data Machine agent with the Agents API.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/opencode-subagents.sh"

opencode_project_subagents() {
  return 1
}

PENDING_ITEMS=()
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
