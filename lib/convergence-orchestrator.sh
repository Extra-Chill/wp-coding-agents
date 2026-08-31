#!/bin/bash
# Shared profile -> explicit plan -> bounded apply -> verify orchestration.

convergence_plan() {
  local operation="$1"
  reconciler_plan_reset
  RECONCILER_ENTRYPOINT="${CONVERGENCE_ENTRYPOINT:-$0}"
  RECONCILER_REPLAY_ARGUMENTS="${CONVERGENCE_REPLAY_ARGUMENTS:-}"
  log "[desired-state] profile=$(installation_profile_record)"
  case "${CONVERGENCE_SCOPE:-all}" in
    all)
      integration_adapters_plan
      runtime_guidance_desired_state_plan
      bridge_service_adapters_plan "$operation"
      ;;
    runtime)
      runtime_guidance_desired_state_plan
      ;;
    agents-md)
      RUNTIME_GUIDANCE_DESIRED_SCOPE=agents-md runtime_guidance_desired_state_plan
      ;;
    bridge)
      BRIDGE_SERVICE_ADAPTER_SCOPE=bridge bridge_service_adapters_plan "$operation"
      ;;
    services)
      integration_adapters_plan
      bridge_service_adapters_plan "$operation"
      ;;
    *)
      error "Unknown convergence scope: ${CONVERGENCE_SCOPE}"
      return 1
      ;;
  esac
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
