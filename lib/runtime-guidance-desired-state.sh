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
    runtime_guidance_desired_state_add guidance.agents-md guidance.reconcile.sections guidance_sync_all
  fi

  if runtime_guidance_desired_state_has_component runtime && [ -n "$runtime" ]; then
    local external_context=false
    if [ "${INSTALLATION_PROFILE_EXTERNAL_WORDPRESS:-${EXTERNAL_WORDPRESS:-false}}" = true ] && \
       declare -F external_wordpress_project_context >/dev/null 2>&1; then
      # Projection follows Data Machine path discovery, matching setup's
      # existing external-runtime ordering before config generation.
      external_context=true
    fi
    local capability function
    while IFS=':' read -r capability function; do
      declare -F "$function" >/dev/null 2>&1 || continue
      runtime_guidance_desired_state_add \
        "runtime.${runtime}.${capability}" \
        "runtime.reconcile.${capability}" \
        "$function"
      if [ "$capability" = paths ] && [ "$external_context" = true ]; then
        runtime_guidance_desired_state_add \
          "runtime.${runtime}.context" \
          runtime.reconcile.context \
          external_wordpress_project_context
      fi
    done <<'EOF'
install:runtime_install
paths:runtime_discover_dm_paths
config:runtime_generate_config
hooks:runtime_install_hooks
instructions:runtime_generate_instructions
mcp:runtime_merge_mcp_servers
EOF
  fi

  # External WordPress intentionally has no local mu-plugin surface. Its
  # runtime records remain, but the runtime guard does not apply.
  if [ "${INSTALLATION_PROFILE_EXTERNAL_WORDPRESS:-${EXTERNAL_WORDPRESS:-false}}" != true ] && \
     runtime_guidance_desired_state_has_component runtime && \
     declare -F runtime_guard_sync >/dev/null 2>&1; then
    # runtime_guard_sync retains its existing source-policy behavior: install
    # in owned mode and remove an obsolete guard in workspace mode.
    runtime_guidance_desired_state_add runtime.guard runtime.reconcile.guard runtime_guard_sync
  fi
}

# plan — append this adapter's records to the active reconciler plan. The
# caller owns reset so this can compose with plugin, service, and bridge plans.
runtime_guidance_desired_state_plan() {
  local index
  runtime_guidance_desired_state_detect
  for index in "${!RUNTIME_GUIDANCE_DESIRED_RECORDS[@]}"; do
    reconciler_plan_add \
      "${RUNTIME_GUIDANCE_DESIRED_RECORDS[$index]}" \
      "${RUNTIME_GUIDANCE_DESIRED_OPERATIONS[$index]}" \
      "${RUNTIME_GUIDANCE_DESIRED_APPLIES[$index]}" \
      "${RUNTIME_GUIDANCE_DESIRED_VERIFIES[$index]}"
  done
}

# apply and verify — use the shared plan executor so partial-record evidence
# and future per-record verification stay consistent with other adapters.
runtime_guidance_desired_state_apply() {
  reconciler_apply_plan
}

runtime_guidance_desired_state_verify() {
  reconciler_verify_plan
}
