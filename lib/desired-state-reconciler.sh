#!/bin/bash
# Credential-free installation profiles and desired-state plan execution.

INSTALLATION_OPERATION_SETUP="setup"
INSTALLATION_OPERATION_UPGRADE="upgrade"
INSTALLATION_OPERATION_PLUGINS_ONLY="plugins-only"

installation_profile_file() {
  printf '%s/.wp-coding-agents/installation-profile' "${SITE_PATH:-${EXISTING_WP:-}}"
}

installation_profile_value() {
  # Profiles are deliberately a small allowlist. Never serialize the process
  # environment: it contains command transports and optional credentials.
  case "$1" in
    operation) printf '%s' "$INSTALLATION_PROFILE_OPERATION" ;;
    site_path) printf '%s' "$INSTALLATION_PROFILE_SITE_PATH" ;;
    local_mode) printf '%s' "$INSTALLATION_PROFILE_LOCAL_MODE" ;;
    external_wordpress) printf '%s' "$INSTALLATION_PROFILE_EXTERNAL_WORDPRESS" ;;
    studio) printf '%s' "$INSTALLATION_PROFILE_STUDIO" ;;
    source_mode) printf '%s' "$INSTALLATION_PROFILE_SOURCE_MODE" ;;
    runtime) printf '%s' "$INSTALLATION_PROFILE_RUNTIME" ;;
    chat_bridge) printf '%s' "$INSTALLATION_PROFILE_CHAT_BRIDGE" ;;
    homeboy_mode) printf '%s' "$INSTALLATION_PROFILE_HOMEBOY_MODE" ;;
    components) printf '%s' "${INSTALLATION_PROFILE_COMPONENTS[*]}" ;;
    plugin_candidates) printf '%s' "${INSTALLATION_PROFILE_PLUGIN_CANDIDATES[*]}" ;;
    *) return 1 ;;
  esac
}

installation_profile_normalize() {
  local operation="$1"
  case "$operation" in
    "$INSTALLATION_OPERATION_SETUP"|"$INSTALLATION_OPERATION_UPGRADE"|"$INSTALLATION_OPERATION_PLUGINS_ONLY") ;;
    *) error "Unknown installation operation: $operation" ;;
  esac

  INSTALLATION_PROFILE_OPERATION="$operation"
  INSTALLATION_PROFILE_SITE_PATH="${SITE_PATH:-${EXISTING_WP:-}}"
  INSTALLATION_PROFILE_LOCAL_MODE="${LOCAL_MODE:-false}"
  INSTALLATION_PROFILE_EXTERNAL_WORDPRESS="${EXTERNAL_WORDPRESS:-false}"
  INSTALLATION_PROFILE_STUDIO="${IS_STUDIO:-false}"
  INSTALLATION_PROFILE_SOURCE_MODE="${SOURCE_MODE:-workspace}"
  INSTALLATION_PROFILE_RUNTIME="${RUNTIME:-}"
  INSTALLATION_PROFILE_CHAT_BRIDGE="${CHAT_BRIDGE:-}"
  INSTALLATION_PROFILE_HOMEBOY_MODE="${HOMEBOY_MODE:-auto}"
  INSTALLATION_PROFILE_PLUGIN_CANDIDATES=(data-machine data-machine-code wp-codebox)
  if [ "$operation" = "$INSTALLATION_OPERATION_PLUGINS_ONLY" ]; then
    INSTALLATION_PROFILE_COMPONENTS=(plugins)
  else
    INSTALLATION_PROFILE_COMPONENTS=(plugins runtime guidance bridge homeboy managed-release services)
  fi
}

installation_profile_record() {
  local components="${INSTALLATION_PROFILE_COMPONENTS[*]}"
  if [ "$INSTALLATION_PROFILE_OPERATION" = "$INSTALLATION_OPERATION_PLUGINS_ONLY" ]; then
    # Preserve the compact plugins-only evidence emitted by the initial #455
    # slice; callers use it as the narrow-operation replay record.
    printf 'operation=%s site_path=%s local=%s external_wordpress=%s studio=%s components=%s\n' \
      "$INSTALLATION_PROFILE_OPERATION" "$INSTALLATION_PROFILE_SITE_PATH" \
      "$INSTALLATION_PROFILE_LOCAL_MODE" "$INSTALLATION_PROFILE_EXTERNAL_WORDPRESS" \
      "$INSTALLATION_PROFILE_STUDIO" "${INSTALLATION_PROFILE_PLUGIN_CANDIDATES[*]}"
    return 0
  fi
  printf 'operation=%s site_path=%s local=%s external_wordpress=%s studio=%s source_mode=%s runtime=%s chat_bridge=%s homeboy_mode=%s components=%s\n' \
    "$INSTALLATION_PROFILE_OPERATION" "$INSTALLATION_PROFILE_SITE_PATH" \
    "$INSTALLATION_PROFILE_LOCAL_MODE" "$INSTALLATION_PROFILE_EXTERNAL_WORDPRESS" \
    "$INSTALLATION_PROFILE_STUDIO" "$INSTALLATION_PROFILE_SOURCE_MODE" \
    "$INSTALLATION_PROFILE_RUNTIME" "$INSTALLATION_PROFILE_CHAT_BRIDGE" \
    "$INSTALLATION_PROFILE_HOMEBOY_MODE" "$components"
}

installation_profile_write() {
  local file tmp key
  [ "${DRY_RUN:-false}" = true ] && return 0
  file="$(installation_profile_file)"
  if ! mkdir -p "${file%/*}" 2>/dev/null || [ ! -w "${file%/*}" ]; then
    # An upgrade may deliberately run as a non-root service identity against a
    # root-owned legacy web tree. Convergence must still proceed; the existing
    # profile remains valid and the next writable reconciliation can refresh it.
    warn "[desired-state] installation profile unchanged: ${file%/*} is not writable"
    return 0
  fi
  tmp="${file}.tmp.$$"
  for key in operation site_path local_mode external_wordpress studio source_mode runtime chat_bridge homeboy_mode components plugin_candidates; do
    printf '%s=%s\n' "$key" "$(installation_profile_value "$key")" >> "$tmp"
  done
  mv "$tmp" "$file"
  chmod 600 "$file"
}

installation_profile_load() {
  local file key value
  file="$(installation_profile_file)"
  [ -f "$file" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      source_mode) [ "${SOURCE_MODE_EXPLICIT:-false}" = true ] || SOURCE_MODE="$value" ;;
      runtime) [ -n "${RUNTIME:-}" ] || RUNTIME="$value" ;;
      chat_bridge) [ -n "${CHAT_BRIDGE:-}" ] || CHAT_BRIDGE="$value" ;;
      homeboy_mode) [ "${HOMEBOY_MODE:-auto}" != auto ] || HOMEBOY_MODE="$value" ;;
    esac
  done < "$file"
}

reconciler_plan_reset() {
  RECONCILER_PLAN_RECORDS=()
  RECONCILER_PLAN_OPERATIONS=()
  RECONCILER_PLAN_APPLY=()
  RECONCILER_PLAN_VERIFY_STEPS=()
  RECONCILER_PLAN_TIMEOUTS=()
  RECONCILER_PLAN_REPLAYS=()
  RECONCILER_PLAN_VERIFY=""
  RECONCILER_COMPLETED_RECORDS=()
  RECONCILER_CHANGED_RECORDS=()
  RECONCILER_UNCHANGED_RECORDS=()
  RECONCILER_STARTED_AT=""
}

reconciler_plan_add() {
  local record="$1" operation="$2" apply="$3" verify="${4:-}" timeout="${5:-}" replay="${6:-}"
  RECONCILER_PLAN_RECORDS+=("$record")
  RECONCILER_PLAN_OPERATIONS+=("$operation")
  RECONCILER_PLAN_APPLY+=("$apply")
  RECONCILER_PLAN_VERIFY_STEPS+=("$verify")
  RECONCILER_PLAN_TIMEOUTS+=("$timeout")
  RECONCILER_PLAN_REPLAYS+=("$replay")
  log "[desired-state] record=$record operation=$operation planned${timeout:+ timeout=${timeout}s}${replay:+ replay=$replay}"
}

reconciler_plan_set_verify() {
  RECONCILER_PLAN_VERIFY="$1"
}

reconciler_apply_plan() {
  local index record operation apply verify timeout replay status=0 step_status changed
  RECONCILER_STARTED_AT="${RECONCILER_STARTED_AT:-$(date +%s)}"
  for index in "${!RECONCILER_PLAN_RECORDS[@]}"; do
    record="${RECONCILER_PLAN_RECORDS[$index]}"
    operation="${RECONCILER_PLAN_OPERATIONS[$index]}"
    apply="${RECONCILER_PLAN_APPLY[$index]}"
    verify="${RECONCILER_PLAN_VERIFY_STEPS[$index]}"
    timeout="${RECONCILER_PLAN_TIMEOUTS[$index]}"
    replay="${RECONCILER_PLAN_REPLAYS[$index]}"
    timeout="${timeout:-${DESIRED_STATE_STEP_TIMEOUT_SECONDS:-120}}"
    replay="${replay:-$(reconciler_replay_command)}"
    log "[desired-state] record=$record operation=$operation apply=start timeout=${timeout}s replay=$replay"
    if reconciler_run_bounded "$record" "$operation" "$timeout" "$apply"; then
      RECONCILER_COMPLETED_RECORDS+=("$record")
      if [ -n "$verify" ] && ! "$verify"; then
        step_status=$?
        status="${PLUGIN_UPDATE_EXIT_PARTIAL:-75}"
        warn "[desired-state] record=$record operation=$operation verify=failed status=$step_status replay=$replay"
      else
        changed="${RECONCILER_STEP_CHANGED:-false}"
        if [ "$changed" = true ]; then
          RECONCILER_CHANGED_RECORDS+=("$record")
          log "[desired-state] record=$record operation=$operation apply=complete changed=true replay=$replay"
        else
          RECONCILER_UNCHANGED_RECORDS+=("$record")
          log "[desired-state] record=$record operation=$operation apply=complete changed=false replay=$replay"
        fi
      fi
    else
      step_status=$?
      status="${PLUGIN_UPDATE_EXIT_PARTIAL:-75}"
      if [ "$step_status" -eq 124 ]; then
        warn "[desired-state] record=$record operation=$operation apply=timeout timeout=${timeout}s replay=$replay"
      else
        warn "[desired-state] record=$record operation=$operation apply=failed status=$step_status replay=$replay"
      fi
    fi
  done
  return "$status"
}

reconciler_replay_command() {
  local script="${RECONCILER_ENTRYPOINT:-${0:-setup.sh}}"
  printf '%q%s' "$script" " ${RECONCILER_REPLAY_ARGUMENTS:-}"
}

# Adapters run in this shell because their explicit outcomes and service-state
# bookkeeping are shell state. Nested commands retain their own bounded runners;
# the engine enforces an aggregate budget and rejects a step that exceeds it.
reconciler_run_bounded() {
  local record="$1" operation="$2" timeout="$3" apply="$4"
  local total="${DESIRED_STATE_TOTAL_TIMEOUT_SECONDS:-480}" now elapsed remaining
  local started status=0
  case "$timeout" in ''|*[!0-9]*|0) timeout=120 ;; esac
  case "$total" in ''|*[!0-9]*|0) total=480 ;; esac
  now="$(date +%s)"; elapsed=$((now - RECONCILER_STARTED_AT)); remaining=$((total - elapsed))
  if [ "$remaining" -le 0 ]; then
    warn "[desired-state] record=$record operation=$operation apply=timeout aggregate_timeout=${total}s"
    return 124
  fi
  [ "$remaining" -lt "$timeout" ] && timeout="$remaining"
  started="$(date +%s)"
  RECONCILER_STEP_CHANGED=false
  if "$apply"; then status=0; else status=$?; fi
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -gt "$timeout" ]; then
    warn "[desired-state] record=$record operation=$operation deadline-exceeded elapsed=${elapsed}s timeout=${timeout}s"
    return 124
  fi
  return "$status"
}

reconciler_adapter_changed() {
  RECONCILER_STEP_CHANGED=true
}

reconciler_mark_changed() {
  local record="$1"
  RECONCILER_CHANGED_RECORDS+=("$record")
  log "[desired-state] record=$record result=changed"
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
