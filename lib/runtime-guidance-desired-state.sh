#!/bin/bash
# Runtime and AGENTS.md guidance desired-state adapter.
#
# Entry points source the selected runtime and guidance dispatcher before this
# module. This adapter deliberately treats their exported functions as
# capabilities so new runtimes do not require reconciler changes.

runtime_guidance_desired_state_has_component() {
  local component="$1"
  local candidate
  for candidate in "${INSTALLATION_PROFILE_COMPONENTS[@]:-}"; do
    [ "$candidate" = "$component" ] && return 0
  done
  return 1
}

runtime_guidance_desired_state_add() {
  RUNTIME_GUIDANCE_DESIRED_RECORDS+=("$1")
  RUNTIME_GUIDANCE_DESIRED_OPERATIONS+=("$2")
  RUNTIME_GUIDANCE_DESIRED_APPLIES+=("$3")
  RUNTIME_GUIDANCE_DESIRED_VERIFIES+=("${4:-}")
}

# detect — derive the runtime and guidance records from the persisted profile
# and the optional capabilities exported by the currently selected runtime.
runtime_guidance_desired_state_detect() {
  RUNTIME_GUIDANCE_DESIRED_RECORDS=()
  RUNTIME_GUIDANCE_DESIRED_OPERATIONS=()
  RUNTIME_GUIDANCE_DESIRED_APPLIES=()
  RUNTIME_GUIDANCE_DESIRED_VERIFIES=()

  local runtime="${INSTALLATION_PROFILE_RUNTIME:-${RUNTIME:-}}"
  # Guidance comes first: runtime instruction generation may compose AGENTS.md
  # immediately after its runtime-specific files are installed.
  if [ "${INSTALLATION_PROFILE_EXTERNAL_WORDPRESS:-${EXTERNAL_WORDPRESS:-false}}" != true ] && \
     runtime_guidance_desired_state_has_component guidance && \
     declare -F guidance_sync_all >/dev/null 2>&1; then
    runtime_guidance_desired_state_add guidance.agents-md guidance.reconcile.sections runtime_guidance_desired_state_apply_guidance
  fi

  RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS=()
  if runtime_guidance_desired_state_has_component runtime && [ -n "$runtime" ]; then
    local function
    for function in runtime_install runtime_discover_dm_paths; do
      declare -F "$function" >/dev/null 2>&1 && RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS+=("$function")
    done
    if [ "${INSTALLATION_PROFILE_EXTERNAL_WORDPRESS:-${EXTERNAL_WORDPRESS:-false}}" = true ] && \
       declare -F external_wordpress_project_context >/dev/null 2>&1; then
      RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS+=(external_wordpress_project_context)
    fi
    for function in runtime_generate_config runtime_install_hooks runtime_generate_instructions runtime_merge_mcp_servers; do
      declare -F "$function" >/dev/null 2>&1 && RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS+=("$function")
    done
  fi

  # External WordPress intentionally has no local mu-plugin surface. Its
  # runtime records remain, but the runtime guard does not apply.
  if [ "${INSTALLATION_PROFILE_EXTERNAL_WORDPRESS:-${EXTERNAL_WORDPRESS:-false}}" != true ] && \
     runtime_guidance_desired_state_has_component runtime && \
     declare -F runtime_guard_sync >/dev/null 2>&1; then
    # runtime_guard_sync retains its existing source-policy behavior: install
    # in owned mode and remove an obsolete guard in workspace mode.
    RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS+=(runtime_guard_sync)
  fi

  if [ "${#RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS[@]}" -gt 0 ]; then
    runtime_guidance_desired_state_add "runtime.${runtime}" runtime.reconcile runtime_guidance_desired_state_apply_runtime
  fi
}

# plan — append this adapter's records to the active reconciler plan. The
# caller owns reset so this can compose with plugin, service, and bridge plans.
runtime_guidance_desired_state_plan() {
  local index timeout
  runtime_guidance_desired_state_detect
  if [ "${RUNTIME_GUIDANCE_DESIRED_SCOPE:-all}" = agents-md ]; then
    for index in "${!RUNTIME_GUIDANCE_DESIRED_RECORDS[@]}"; do
      [ "${RUNTIME_GUIDANCE_DESIRED_RECORDS[$index]}" = guidance.agents-md ] || continue
      reconciler_plan_add \
        "${RUNTIME_GUIDANCE_DESIRED_RECORDS[$index]}" \
        "${RUNTIME_GUIDANCE_DESIRED_OPERATIONS[$index]}" \
        "${RUNTIME_GUIDANCE_DESIRED_APPLIES[$index]}"
    done
    if declare -F runtime_generate_instructions >/dev/null 2>&1; then
      reconciler_plan_add "runtime.${INSTALLATION_PROFILE_RUNTIME}.instructions" \
        runtime.reconcile.instructions runtime_guidance_desired_state_apply_instructions
    fi
    return 0
  fi
  for index in "${!RUNTIME_GUIDANCE_DESIRED_RECORDS[@]}"; do
    timeout=""
    if [ "${RUNTIME_GUIDANCE_DESIRED_RECORDS[$index]}" = "runtime.${INSTALLATION_PROFILE_RUNTIME}" ]; then
      timeout="${DESIRED_STATE_RUNTIME_TIMEOUT_SECONDS:-360}"
    fi
    reconciler_plan_add \
      "${RUNTIME_GUIDANCE_DESIRED_RECORDS[$index]}" \
      "${RUNTIME_GUIDANCE_DESIRED_OPERATIONS[$index]}" \
      "${RUNTIME_GUIDANCE_DESIRED_APPLIES[$index]}" \
      "${RUNTIME_GUIDANCE_DESIRED_VERIFIES[$index]}" \
      "$timeout"
  done
}

runtime_guidance_desired_state_apply_function() {
  local function="$1"
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  "$function" || return $?
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

runtime_guidance_desired_state_apply_guidance() { runtime_guidance_desired_state_apply_function guidance_sync_all; }
runtime_guidance_desired_state_apply_runtime() {
  local function
  for function in "${RUNTIME_GUIDANCE_DESIRED_RUNTIME_FUNCTIONS[@]}"; do
    runtime_guidance_desired_state_apply_function "$function" || return $?
  done
}
runtime_guidance_desired_state_apply_instructions() {
  if declare -F runtime_discover_dm_paths >/dev/null 2>&1; then
    runtime_discover_dm_paths || return $?
  fi
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ] && declare -F external_wordpress_project_context >/dev/null 2>&1; then
    external_wordpress_project_context || return $?
  fi
  runtime_guidance_desired_state_apply_function runtime_generate_instructions
}

# Keep an existing managed Codex projection aligned with canonical AGENTS.md
# even when another runtime is primary. The managed marker is explicit
# authority; user-owned AGENTS.override.md files remain untouched.
runtime_guidance_sync_managed_codex_projection() {
  local projection="$SITE_PATH/AGENTS.override.md"
  [ -f "$projection" ] || return 0
  grep -Fq '<!-- WP_CODING_AGENTS_CODEX_OVERRIDE_START -->' "$projection" || return 0

  local selected_runtime_file="${RUNTIME_FILE:-}"
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/runtimes/codex.sh"
  runtime_discover_dm_paths || return $?
  _codex_sync_override || return $?

  if [ "${RUNTIME:-}" != codex ] && [ -n "$selected_runtime_file" ] && [ -f "$selected_runtime_file" ]; then
    # shellcheck disable=SC1090
    source "$selected_runtime_file"
  fi
}

# apply and verify — use the shared plan executor so partial-record evidence
# and future per-record verification stay consistent with other adapters.
runtime_guidance_desired_state_apply() {
  reconciler_apply_plan
}

runtime_guidance_desired_state_verify() {
  reconciler_verify_plan
}
