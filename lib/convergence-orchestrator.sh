#!/bin/bash
# Shared profile -> explicit plan -> bounded apply -> verify orchestration.

convergence_plan() {
  local operation="$1"
  reconciler_plan_reset
  RECONCILER_ENTRYPOINT="${CONVERGENCE_ENTRYPOINT:-$0}"
  RECONCILER_REPLAY_ARGUMENTS="${CONVERGENCE_REPLAY_ARGUMENTS:-}"
  log "[desired-state] profile=$(installation_profile_record)"
  integration_adapters_plan
  if [ "${CONVERGENCE_SCOPE:-all}" = all ]; then
    runtime_guidance_desired_state_plan
  fi
  bridge_service_adapters_plan "$operation"
}

convergence_apply() {
  reconciler_apply_plan
}

convergence_verify() {
  reconciler_verify_plan
}

convergence_run() {
  local operation="$1" status=0
  convergence_plan "$operation"
  convergence_apply || status=$?
  convergence_verify || status=$?
  return "$status"
}
