#!/bin/bash
# Credential-free operation profile and desired-state plan execution.

INSTALLATION_OPERATION_PLUGINS_ONLY="plugins-only"

installation_profile_normalize() {
  local operation="$1"
  case "$operation" in
    "$INSTALLATION_OPERATION_PLUGINS_ONLY") ;;
    *) error "Unknown installation operation: $operation" ;;
  esac

  INSTALLATION_PROFILE_OPERATION="$operation"
  INSTALLATION_PROFILE_SITE_PATH="${SITE_PATH:-${EXISTING_WP:-}}"
  INSTALLATION_PROFILE_LOCAL_MODE="${LOCAL_MODE:-false}"
  INSTALLATION_PROFILE_EXTERNAL_WORDPRESS="${EXTERNAL_WORDPRESS:-false}"
  INSTALLATION_PROFILE_STUDIO="${IS_STUDIO:-false}"
  INSTALLATION_PROFILE_PLUGIN_CANDIDATES=(data-machine data-machine-code wp-codebox)
}

installation_profile_record() {
  printf 'operation=%s site_path=%s local=%s external_wordpress=%s studio=%s components=%s\n' \
    "$INSTALLATION_PROFILE_OPERATION" "$INSTALLATION_PROFILE_SITE_PATH" \
    "$INSTALLATION_PROFILE_LOCAL_MODE" "$INSTALLATION_PROFILE_EXTERNAL_WORDPRESS" \
    "$INSTALLATION_PROFILE_STUDIO" "${INSTALLATION_PROFILE_PLUGIN_CANDIDATES[*]}"
}

reconciler_plan_reset() {
  RECONCILER_PLAN_RECORDS=()
  RECONCILER_PLAN_OPERATIONS=()
  RECONCILER_PLAN_APPLY=()
  RECONCILER_PLAN_VERIFY=""
  RECONCILER_COMPLETED_RECORDS=()
}

reconciler_plan_add() {
  local record="$1" operation="$2" apply="$3"
  RECONCILER_PLAN_RECORDS+=("$record")
  RECONCILER_PLAN_OPERATIONS+=("$operation")
  RECONCILER_PLAN_APPLY+=("$apply")
  log "[desired-state] record=$record operation=$operation planned"
}

reconciler_plan_set_verify() {
  RECONCILER_PLAN_VERIFY="$1"
}

reconciler_apply_plan() {
  local index record operation apply status=0 step_status
  for index in "${!RECONCILER_PLAN_RECORDS[@]}"; do
    record="${RECONCILER_PLAN_RECORDS[$index]}"
    operation="${RECONCILER_PLAN_OPERATIONS[$index]}"
    apply="${RECONCILER_PLAN_APPLY[$index]}"
    log "[desired-state] record=$record operation=$operation apply=start"
    if "$apply"; then
      RECONCILER_COMPLETED_RECORDS+=("$record")
      log "[desired-state] record=$record operation=$operation apply=complete"
    else
      step_status=$?
      status="$PLUGIN_UPDATE_EXIT_PARTIAL"
      warn "[desired-state] record=$record operation=$operation apply=partial-failure status=$step_status"
    fi
  done
  return "$status"
}

reconciler_verify_plan() {
  local status
  [ -n "$RECONCILER_PLAN_VERIFY" ] || return 0
  log "[desired-state] operation=plugins.reconcile.verify verification=start"
  if "$RECONCILER_PLAN_VERIFY"; then
    log "[desired-state] operation=plugins.reconcile.verify verification=complete"
    return 0
  fi
  status=$?
  warn "[desired-state] operation=plugins.reconcile.verify verification=partial-failure status=$status"
  return "$PLUGIN_UPDATE_EXIT_PARTIAL"
}

reconciler_print_partial_evidence() {
  local record
  [ "${#RECONCILER_COMPLETED_RECORDS[@]}" -gt 0 ] || return 0
  warn "DESIRED_STATE_COMPLETED_RECORDS=${RECONCILER_COMPLETED_RECORDS[*]}"
  for record in "${RECONCILER_COMPLETED_RECORDS[@]}"; do
    warn "  completed desired-state record: $record"
  done
}
