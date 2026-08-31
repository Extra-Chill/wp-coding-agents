#!/bin/bash
# Credential-free installation profiles and desired-state plan execution.

INSTALLATION_OPERATION_SETUP="setup"
INSTALLATION_OPERATION_UPGRADE="upgrade"
INSTALLATION_OPERATION_PLUGINS_ONLY="plugins-only"

installation_profile_root() {
  local root="${SITE_PATH:-${EXISTING_WP:-}}"
  [ -n "$root" ] || {
    error "Cannot resolve installation profile without a site path"
    return 1
  }
  printf '%s/.wp-coding-agents' "$root"
}

installation_profile_file() {
  local root
  root="$(installation_profile_root)" || return 1
  printf '%s/installation-profile' "$root"
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
    install_chat) printf '%s' "$INSTALLATION_PROFILE_INSTALL_CHAT" ;;
    chat_bridge) printf '%s' "$INSTALLATION_PROFILE_CHAT_BRIDGE" ;;
    homeboy_mode) printf '%s' "$INSTALLATION_PROFILE_HOMEBOY_MODE" ;;
    workspace_repositories) printf '%s' "$INSTALLATION_PROFILE_WORKSPACE_REPOSITORIES" ;;
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
  INSTALLATION_PROFILE_INSTALL_CHAT="${INSTALL_CHAT:-true}"
  if [ "$INSTALLATION_PROFILE_INSTALL_CHAT" = true ]; then
    INSTALLATION_PROFILE_CHAT_BRIDGE="${CHAT_BRIDGE:-}"
  else
    INSTALLATION_PROFILE_CHAT_BRIDGE=""
  fi
  INSTALLATION_PROFILE_HOMEBOY_MODE="${HOMEBOY_MODE:-auto}"
  INSTALLATION_PROFILE_WORKSPACE_REPOSITORIES="${WORKSPACE_REPOSITORIES:-}"
  INSTALLATION_PROFILE_PLUGIN_CANDIDATES=(data-machine data-machine-code wp-codebox)
  INSTALLATION_PROFILE_CARRIED_PLUGINS=()
  if [ "$INSTALLATION_PROFILE_EXTERNAL_WORDPRESS" != true ]; then
    INSTALLATION_PROFILE_CARRIED_PLUGINS+=(wp-coding-agents-integration)
    local runtime
    for runtime in "${DETECTED_RUNTIMES[@]:-${INSTALLATION_PROFILE_RUNTIME}}"; do
      [ "$runtime" = claude-code ] && INSTALLATION_PROFILE_CARRIED_PLUGINS+=(ai-provider-for-claude-code)
    done
  fi
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
  printf 'operation=%s site_path=%s local=%s external_wordpress=%s studio=%s source_mode=%s runtime=%s install_chat=%s chat_bridge=%s homeboy_mode=%s components=%s\n' \
    "$INSTALLATION_PROFILE_OPERATION" "$INSTALLATION_PROFILE_SITE_PATH" \
    "$INSTALLATION_PROFILE_LOCAL_MODE" "$INSTALLATION_PROFILE_EXTERNAL_WORDPRESS" \
    "$INSTALLATION_PROFILE_STUDIO" "$INSTALLATION_PROFILE_SOURCE_MODE" \
    "$INSTALLATION_PROFILE_RUNTIME" "$INSTALLATION_PROFILE_INSTALL_CHAT" \
    "$INSTALLATION_PROFILE_CHAT_BRIDGE" \
    "$INSTALLATION_PROFILE_HOMEBOY_MODE" "$components"
}

installation_profile_write() {
  local root file tmp
  [ "${DRY_RUN:-false}" = true ] && return 0
  root="$(installation_profile_root)" || return 1
  file="$root/installation-profile"
  if [ -L "$root" ] || [ -L "$file" ]; then
    warn "[desired-state] installation profile unchanged: refusing symlinked state path $root"
    return 0
  fi
  if ! mkdir -p "$root" 2>/dev/null || [ ! -w "$root" ]; then
    # An upgrade may deliberately run as a non-root service identity against a
    # root-owned legacy web tree. Convergence must still proceed; the existing
    # profile remains valid and the next writable reconciliation can refresh it.
    warn "[desired-state] installation profile unchanged: $root is not writable"
    return 0
  fi
  tmp="${file}.tmp.$$"
  (
    local key
    umask 077
    : > "$tmp"
    for key in operation site_path local_mode external_wordpress studio source_mode runtime install_chat chat_bridge homeboy_mode workspace_repositories components plugin_candidates; do
      printf '%s=%s\n' "$key" "$(installation_profile_value "$key")" >> "$tmp"
    done
    mv "$tmp" "$file"
    chmod 600 "$file"
  )
}

installation_profile_load() {
  local root file key value
  root="$(installation_profile_root)" || return 1
  file="$root/installation-profile"
  [ -f "$file" ] || return 0
  if [ -L "$root" ] || [ -L "$file" ]; then
    warn "[desired-state] installation profile ignored: refusing symlinked state path $root"
    return 0
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      source_mode) [ "${SOURCE_MODE_EXPLICIT:-false}" = true ] || SOURCE_MODE="$value" ;;
      runtime) [ -n "${RUNTIME:-}" ] || RUNTIME="$value" ;;
      install_chat)
        case "$value" in
          true|false) INSTALL_CHAT="$value" ;;
          *) error "Invalid install_chat value in installation profile: $value"; return 1 ;;
        esac
        ;;
      chat_bridge) [ -n "${CHAT_BRIDGE:-}" ] || CHAT_BRIDGE="$value" ;;
      homeboy_mode) [ "${HOMEBOY_MODE:-auto}" != auto ] || HOMEBOY_MODE="$value" ;;
      workspace_repositories) [ -n "${WORKSPACE_REPOSITORIES:-}" ] || WORKSPACE_REPOSITORIES="$value" ;;
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
    if reconciler_run_bounded "$record" "$operation" "$timeout" "$apply" apply; then
      changed="${RECONCILER_STEP_CHANGED:-false}"
      if [ -n "$verify" ]; then
        log "[desired-state] record=$record operation=$operation verify=start timeout=${timeout}s replay=$replay"
        if reconciler_run_bounded "$record" "$operation" "$timeout" "$verify" verify; then
          log "[desired-state] record=$record operation=$operation verify=complete replay=$replay"
        else
          step_status=$?
          status="${PLUGIN_UPDATE_EXIT_PARTIAL:-75}"
          if [ "$step_status" -eq 124 ]; then
            warn "[desired-state] record=$record operation=$operation verify=timeout timeout=${timeout}s replay=$replay"
          else
            warn "[desired-state] record=$record operation=$operation verify=failed status=$step_status replay=$replay"
          fi
          continue
        fi
      fi
      RECONCILER_COMPLETED_RECORDS+=("$record")
      if [ "$changed" = true ]; then
        RECONCILER_CHANGED_RECORDS+=("$record")
        log "[desired-state] record=$record operation=$operation apply=complete changed=true replay=$replay"
      else
        RECONCILER_UNCHANGED_RECORDS+=("$record")
        log "[desired-state] record=$record operation=$operation apply=complete changed=false replay=$replay"
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

# Each adapter runs in its own process group. The only child-shell state accepted
# by the parent is this credential-safe outcome file, never the environment.
reconciler_run_bounded() {
  local record="$1" operation="$2" timeout="$3" command="$4" phase="${5:-apply}"
  local total="${DESIRED_STATE_TOTAL_TIMEOUT_SECONDS:-480}" now elapsed remaining
  local started status=0 temp_dir outcome_file pid pgid elapsed restore_monitor=false
  case "$timeout" in ''|*[!0-9]*|0) timeout=120 ;; esac
  case "$total" in ''|*[!0-9]*|0) total=480 ;; esac
  now="$(date +%s)"; elapsed=$((now - RECONCILER_STARTED_AT)); remaining=$((total - elapsed))
  if [ "$remaining" -le 0 ]; then
    warn "[desired-state] record=$record operation=$operation $phase=timeout aggregate_timeout=${total}s"
    return 124
  fi
  [ "$remaining" -lt "$timeout" ] && timeout="$remaining"
  temp_dir="$(mktemp -d)" || return 1
  outcome_file="$temp_dir/outcome"
  started="$(date +%s)"
  case "$-" in *m*) ;; *) set -m; restore_monitor=true ;; esac
  ( RECONCILER_STEP_CHANGED=false; "$command"; status=$?; printf 'changed=%s\n' "$RECONCILER_STEP_CHANGED" > "$outcome_file"; exit "$status" ) &
  pid=$!
  [ "$restore_monitor" = false ] || set +m
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -ge "$timeout" ]; then
      warn "[desired-state] record=$record operation=$operation $phase=deadline-exceeded elapsed=${elapsed}s timeout=${timeout}s"
      if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then kill -TERM -- "-$pgid" 2>/dev/null || true; else kill -TERM "$pid" 2>/dev/null || true; fi
      sleep "${PLUGIN_UPDATE_KILL_GRACE_SECONDS:-2}"
      if kill -0 "$pid" 2>/dev/null; then
        if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then kill -KILL -- "-$pgid" 2>/dev/null || true; else kill -KILL "$pid" 2>/dev/null || true; fi
      fi
      wait "$pid" 2>/dev/null || true
      rm -rf "$temp_dir"
      return 124
    fi
    sleep 1
  done
  if wait "$pid"; then status=0; else status=$?; fi
  RECONCILER_STEP_CHANGED=false
  if [ "$status" -eq 0 ] && [ -f "$outcome_file" ]; then
    case "$(<"$outcome_file")" in changed=true) RECONCILER_STEP_CHANGED=true ;; esac
  fi
  rm -rf "$temp_dir"
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
  local status timeout="${DESIRED_STATE_STEP_TIMEOUT_SECONDS:-120}"
  [ -n "$RECONCILER_PLAN_VERIFY" ] || return 0
  log "[desired-state] operation=plugins.reconcile.verify verification=start"
  if reconciler_run_bounded plugins plugins.reconcile.verify "$timeout" "$RECONCILER_PLAN_VERIFY" verification; then
    log "[desired-state] operation=plugins.reconcile.verify verification=complete"
    return 0
  fi
  status=$?
  warn "[desired-state] operation=plugins.reconcile.verify verification=partial-failure status=$status"
  return "$PLUGIN_UPDATE_EXIT_PARTIAL"
}

reconciler_print_partial_evidence() {
  local record
  if [ "${#RECONCILER_COMPLETED_RECORDS[@]}" -gt 0 ]; then
    warn "DESIRED_STATE_COMPLETED_RECORDS=${RECONCILER_COMPLETED_RECORDS[*]}"
    for record in "${RECONCILER_COMPLETED_RECORDS[@]}"; do
      warn "  completed desired-state record: $record"
    done
  fi
  if [ "${#RECONCILER_CHANGED_RECORDS[@]}" -gt 0 ]; then
    warn "DESIRED_STATE_CHANGED_RECORDS=${RECONCILER_CHANGED_RECORDS[*]}"
    for record in "${RECONCILER_CHANGED_RECORDS[@]}"; do
      warn "  changed desired-state record: $record"
    done
  fi
}
