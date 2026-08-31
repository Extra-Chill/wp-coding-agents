#!/bin/bash
# Desired-state adapters for optional chat bridges and supervised services.
# This module deliberately delegates platform mutations to their existing
# owners; it only makes their presence and plan records explicit.

bridge_service_adapter_names() {
  printf '%s\n' bridge wordpress-service datamachine-worker
}

bridge_service_adapter_operation_validate() {
  case "$1" in
    "$INSTALLATION_OPERATION_SETUP"|"$INSTALLATION_OPERATION_UPGRADE") ;;
    *) error "Unsupported bridge/service adapter operation: $1" ;;
  esac
}

bridge_service_adapter_detect() {
  local adapter="$1" detected=""
  BRIDGE_SERVICE_ADAPTER_PRESENT=false

  case "$adapter" in
    bridge)
      if [ "$BRIDGE_SERVICE_ADAPTER_OPERATION" = "$INSTALLATION_OPERATION_SETUP" ]; then
        [ "${INSTALL_CHAT:-false}" = true ] || return 0
        [ -n "${CHAT_BRIDGE:-}" ] || return 0
      else
        if [ "${RUNTIME:-}" = codex ]; then
          CHAT_BRIDGE=""
          return 0
        elif [ "${LOCAL_MODE:-false}" = true ]; then
          detected="$(bridge_detect_local)"
        else
          detected="$(bridge_detect_vps)"
        fi
        CHAT_BRIDGE="$detected"
        [ -n "$CHAT_BRIDGE" ] || return 0
      fi

      bridge_file "$CHAT_BRIDGE" >/dev/null 2>&1 || return 0
      bridge_load "$CHAT_BRIDGE"
      if [ "$CHAT_BRIDGE" = kimaki ] && [ "${LOCAL_MODE:-false}" = false ] && declare -F _kimaki_resolve_instance >/dev/null 2>&1; then
        _kimaki_resolve_instance
      fi
      BRIDGE_SERVICE_ADAPTER_PRESENT=true
      ;;
    wordpress-service)
      [ "${EXTERNAL_WORDPRESS:-false}" = true ] && return 0
      if [ -n "${WORDPRESS_SERVICE_REQUEST:-}" ] || [ -f "$(wordpress_service_state_file)" ]; then
        BRIDGE_SERVICE_ADAPTER_PRESENT=true
      elif [ "${LOCAL_MODE:-false}" = true ] && [ "${PLATFORM:-}" = mac ] && [ -f "$(wordpress_service_launchd_dir)/$(wordpress_service_label).plist" ]; then
        BRIDGE_SERVICE_ADAPTER_PRESENT=true
      fi
      ;;
    datamachine-worker)
      [ "${EXTERNAL_WORDPRESS:-false}" = true ] && return 0
      if [ -n "${DATAMACHINE_WORKER_REQUEST:-${WP_CODING_AGENTS_DATAMACHINE_WORKER_ENABLED:-}}" ] || [ -f "$(datamachine_worker_state_file)" ]; then
        BRIDGE_SERVICE_ADAPTER_PRESENT=true
      elif [ "${LOCAL_MODE:-false}" = true ] && [ "${PLATFORM:-}" = mac ] && [ -f "$(datamachine_worker_launchd_dir)/$(datamachine_worker_launchd_label).plist" ]; then
        BRIDGE_SERVICE_ADAPTER_PRESENT=true
      elif [ "${LOCAL_MODE:-false}" = false ] && { [ -f "$(datamachine_worker_systemd_dir)/datamachine-worker.service" ] || [ -f "$(datamachine_worker_systemd_dir)/datamachine-worker.timer" ]; }; then
        BRIDGE_SERVICE_ADAPTER_PRESENT=true
      fi
      ;;
    *) error "Unknown bridge/service adapter: $adapter" ;;
  esac
}

bridge_service_adapter_record() {
  case "$1" in
    bridge) printf 'bridges.%s' "$CHAT_BRIDGE" ;;
    wordpress-service) printf 'services.wordpress' ;;
    datamachine-worker) printf 'services.datamachine-worker' ;;
  esac
}

bridge_service_adapter_plan() {
  local adapter="$1" record
  bridge_service_adapter_detect "$adapter"
  [ "$BRIDGE_SERVICE_ADAPTER_PRESENT" = true ] || return 0
  record="$(bridge_service_adapter_record "$adapter")"
  reconciler_plan_add "$record" "bridge-services.reconcile.$adapter" \
    "bridge_service_adapter_apply_${adapter//-/_}" \
    "bridge_service_adapter_verify_${adapter//-/_}"
}

bridge_service_adapters_plan() {
  local operation="$1" adapter
  bridge_service_adapter_operation_validate "$operation"
  BRIDGE_SERVICE_ADAPTER_OPERATION="$operation"
  for adapter in $(bridge_service_adapter_names); do
    bridge_service_adapter_plan "$adapter"
  done
}

bridge_service_adapter_apply_bridge() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  if [ "$BRIDGE_SERVICE_ADAPTER_OPERATION" = "$INSTALLATION_OPERATION_SETUP" ]; then
    bridge_install
    declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
    return
  fi
  bridge_sync_config
  if [ "${LOCAL_MODE:-false}" = true ]; then
    if [ "${PLATFORM:-}" = mac ] && bridge_has_hook update_launchd; then
      bridge_update_launchd
    fi
    declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
    return 0
  elif [ "${EUID:-$(id -u)}" -eq 0 ]; then
    bridge_update_systemd
  else
    warn "Skipping chat bridge unit refresh because upgrade is running non-root"
  fi
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

bridge_service_adapter_apply_wordpress_service() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  wordpress_service_reconcile
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

bridge_service_adapter_apply_datamachine_worker() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  datamachine_worker_reconcile
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

bridge_service_adapter_verify_bridge() {
  bridge_file "$CHAT_BRIDGE" >/dev/null 2>&1 && bridge_has_hook install && bridge_has_hook sync_config
}

bridge_service_adapter_verify_wordpress_service() {
  wordpress_service_desired_state >/dev/null
}

bridge_service_adapter_verify_datamachine_worker() {
  datamachine_worker_desired_state >/dev/null
}
