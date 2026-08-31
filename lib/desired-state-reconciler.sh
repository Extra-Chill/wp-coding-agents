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
    for key in operation site_path local_mode external_wordpress studio source_mode runtime install_chat chat_bridge homeboy_mode components plugin_candidates; do
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
    esac
  done < "$file"
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
