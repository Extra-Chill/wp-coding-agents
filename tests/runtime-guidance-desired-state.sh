#!/bin/bash
# Behavioral contract for the runtime + guidance desired-state adapter.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/lib/desired-state-reconciler.sh"
source "$ROOT_DIR/lib/runtime-guidance-desired-state.sh"

log() { :; }
warn() { :; }

guidance_sync_all() { :; }
runtime_guard_sync() { :; }
external_wordpress_project_context() { :; }

records_for() {
  local operation="$1" runtime="$2" external="$3" components="$4" without_mcp="${5:-false}"
  if [ -n "$runtime" ]; then
    # shellcheck disable=SC1090
    source "$ROOT_DIR/runtimes/$runtime.sh"
  fi
  [ "$without_mcp" != true ] || unset -f runtime_merge_mcp_servers
  INSTALLATION_PROFILE_OPERATION="$operation"
  INSTALLATION_PROFILE_RUNTIME="$runtime"
  INSTALLATION_PROFILE_EXTERNAL_WORDPRESS="$external"
  INSTALLATION_PROFILE_COMPONENTS=($components)
  RUNTIME="$runtime"
  reconciler_plan_reset
  runtime_guidance_desired_state_plan
  printf '%s\n' "${RECONCILER_PLAN_RECORDS[@]:-}"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    echo "got:  $got" >&2
    echo "want: $want" >&2
    exit 1
  fi
}

expected_runtime_records() {
  local runtime="$1"
  printf 'guidance.agents-md\nruntime.%s' "$runtime"
}

for runtime in opencode claude-code codex; do
  setup_records="$(records_for setup "$runtime" false 'runtime guidance')"
  upgrade_records="$(records_for upgrade "$runtime" false 'runtime guidance')"
  assert_eq "$setup_records" "$upgrade_records" "$runtime setup and upgrade derive equivalent records"
  assert_eq "$setup_records" "$(expected_runtime_records "$runtime")" "$runtime exposes its supported runtime and guidance records"
done

source "$ROOT_DIR/runtimes/opencode.sh"
INSTALLATION_PROFILE_RUNTIME=opencode
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=false
INSTALLATION_PROFILE_COMPONENTS=(runtime guidance)
reconciler_plan_reset
runtime_guidance_desired_state_plan
[ "${RECONCILER_PLAN_TIMEOUTS[1]}" = 360 ] || { echo "FAIL: aggregate runtime timeout" >&2; exit 1; }

external_records="$(records_for setup opencode true 'runtime guidance')"
assert_eq "$external_records" "runtime.opencode" "external WordPress omits local guidance records"

optional_records="$(records_for upgrade opencode false 'runtime guidance' true)"
assert_eq "$optional_records" "guidance.agents-md
runtime.opencode" "an unavailable optional runtime capability is omitted"

absent_records="$(records_for upgrade '' false 'plugins')"
assert_eq "$absent_records" "" "absent optional runtime and guidance produce no records"

# Runtime capabilities execute as one ordered component so path/context state
# reaches config and instruction generation inside the bounded child.
TRACE="$(mktemp)"
runtime_install() { printf 'install\n' >> "$TRACE"; }
runtime_discover_dm_paths() { DM_AGENT_FILES='memory/SOUL.md'; printf 'paths\n' >> "$TRACE"; }
external_wordpress_project_context() { DM_AGENT_FILES="$DM_AGENT_FILES memory/REMOTE.md"; printf 'context\n' >> "$TRACE"; }
runtime_generate_config() { [ "$DM_AGENT_FILES" = 'memory/SOUL.md memory/REMOTE.md' ]; printf 'config\n' >> "$TRACE"; }
runtime_install_hooks() { printf 'hooks\n' >> "$TRACE"; }
runtime_generate_instructions() { [ "$DM_AGENT_FILES" = 'memory/SOUL.md memory/REMOTE.md' ]; printf 'instructions\n' >> "$TRACE"; }
runtime_merge_mcp_servers() { printf 'mcp\n' >> "$TRACE"; }
INSTALLATION_PROFILE_RUNTIME=fixture
INSTALLATION_PROFILE_EXTERNAL_WORDPRESS=true
INSTALLATION_PROFILE_COMPONENTS=(runtime)
EXTERNAL_WORDPRESS=true
reconciler_plan_reset
runtime_guidance_desired_state_plan
reconciler_apply_plan
assert_eq "$(<"$TRACE")" $'install\npaths\ncontext\nconfig\nhooks\ninstructions\nmcp' "runtime state survives its ordered component step"
rm -f "$TRACE"

echo "OK: runtime and guidance desired-state adapter"
