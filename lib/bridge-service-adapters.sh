#!/bin/bash
# Desired-state adapters for optional chat bridges and supervised services.
# This module deliberately delegates platform mutations to their existing
# owners; it only makes their presence and plan records explicit.

bridge_service_adapter_names() {
  printf '%s\n' agent-tmpdir bridge wordpress-service datamachine-worker homeboy-daemon
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
    agent-tmpdir)
      [ -n "${AGENT_TMPDIR:-}" ] && BRIDGE_SERVICE_ADAPTER_PRESENT=true
      ;;
    bridge)
      [ "${INSTALL_CHAT:-false}" = true ] || return 0
      if [ "$BRIDGE_SERVICE_ADAPTER_OPERATION" = "$INSTALLATION_OPERATION_SETUP" ]; then
        [ -n "${CHAT_BRIDGE:-}" ] || return 0
      else
        if [ "${LOCAL_MODE:-false}" = true ]; then
          detected="$(bridge_detect_local)"
        else
          detected="$(bridge_detect_vps)"
        fi
        CHAT_BRIDGE="$detected"
        [ -n "$CHAT_BRIDGE" ] || return 0
      fi

      bridge_file "$CHAT_BRIDGE" >/dev/null 2>&1 || return 0
      bridge_load "$CHAT_BRIDGE"
      if [ "$CHAT_BRIDGE" = roadie ] && [ "${LOCAL_MODE:-false}" = false ] && declare -F _roadie_resolve_instance >/dev/null 2>&1; then
        _roadie_resolve_instance
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
    homeboy-daemon)
      # Owned whenever this install owns a service-owned Homeboy under systemd.
      declare -F homeboy_daemon_service_applicable >/dev/null 2>&1 || return 0
      homeboy_daemon_service_applicable && BRIDGE_SERVICE_ADAPTER_PRESENT=true
      ;;
    *) error "Unknown bridge/service adapter: $adapter" ;;
  esac
  return 0
}

bridge_service_adapter_record() {
  case "$1" in
    agent-tmpdir) printf 'services.agent-tmpdir' ;;
    bridge) printf 'bridges.%s' "$CHAT_BRIDGE" ;;
    wordpress-service) printf 'services.wordpress' ;;
    datamachine-worker) printf 'services.datamachine-worker' ;;
    homeboy-daemon) printf 'services.homeboy-daemon' ;;
  esac
}

bridge_service_adapter_plan() {
  local adapter="$1" record timeout=""
  bridge_service_adapter_detect "$adapter"
  [ "$BRIDGE_SERVICE_ADAPTER_PRESENT" = true ] || return 0
  record="$(bridge_service_adapter_record "$adapter")"
  # Reconciling the chat bridge can include a one-time state migration (e.g.
  # copying a multi-GB SQLite session database between bridges with
  # `sqlite3 .backup` plus an integrity check). The default 120s step budget
  # cut that off mid-copy, so the bridge record gets the same longer budget
  # as the runtime record.
  [ "$adapter" = bridge ] && timeout="${DESIRED_STATE_BRIDGE_TIMEOUT_SECONDS:-420}"
  reconciler_plan_add "$record" "bridge-services.reconcile.$adapter" \
    "bridge_service_adapter_apply_${adapter//-/_}" \
    "bridge_service_adapter_verify_${adapter//-/_}" \
    "$timeout"
}

bridge_service_adapters_plan() {
  local operation="$1" adapter
  bridge_service_adapter_operation_validate "$operation"
  BRIDGE_SERVICE_ADAPTER_OPERATION="$operation"
  for adapter in $(bridge_service_adapter_names); do
    # Units of every scope reference TMPDIR, so its directory always reconciles first.
    [ "${BRIDGE_SERVICE_ADAPTER_SCOPE:-all}" != bridge ] || [ "$adapter" = bridge ] || [ "$adapter" = agent-tmpdir ] || continue
    bridge_service_adapter_plan "$adapter"
  done
}

# systemd-tmpfiles creates agent scratch at boot and ages out files older than
# AGENT_TMPDIR_MAX_AGE through systemd-tmpfiles-clean.timer. The entry is also
# the persisted record source_policy_resolve_agent_tmpdir reads back.

agent_tmpdir_render_tmpfiles() {
  local group
  group="$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")"
  printf 'd %s 0700 %s %s %s\n' "$AGENT_TMPDIR" "$SERVICE_USER" "$group" "${AGENT_TMPDIR_MAX_AGE:-3d}"
}

agent_tmp_sweep_applicable() {
  [ -n "${AGENT_TMPDIR:-}" ] && [ "${LOCAL_MODE:-false}" != true ] &&
    [ "${PLATFORM:-}" != mac ] && [ -d /run/systemd/system ]
}

agent_tmp_sweep_systemd_dir() { printf '%s' "${AGENT_TMP_SWEEP_SYSTEMD_DIR:-/etc/systemd/system}"; }
agent_tmp_sweep_script() { printf '%s' "${AGENT_TMP_SWEEP_SCRIPT:-/usr/local/lib/wp-coding-agents/agent-tmp-sweep.py}"; }

agent_tmp_sweep_render_service() {
  local age="${AGENT_TMP_SWEEP_MAX_AGE:-${AGENT_TMPDIR_MAX_AGE:-3d}}"
  [[ "$age" =~ ^[1-9][0-9]*[smhdw]$ ]] || { warn "Invalid agent sweep age: $age"; return 1; }
  [ -n "${SERVICE_USER:-}" ] && [ "$SERVICE_USER" != root ] && [ "$SERVICE_USER" != 0 ] || return 1
  cat <<EOF
[Unit]
Description=Clean stale agent-owned system temporary files
[Service]
Type=oneshot
User=$SERVICE_USER
ExecStart=/usr/bin/python3 $(agent_tmp_sweep_script) $age
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/tmp
PrivateTmp=false
RestrictSUIDSGID=true
EOF
}

agent_tmp_sweep_render_timer() {
  cat <<'EOF'
[Unit]
Description=Daily stale agent scratch cleanup
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
EOF
}

agent_tmp_sweep_install() {
  agent_tmp_sweep_applicable || return 0
  local service
  service="$(agent_tmp_sweep_render_service)" || return 1
  if [ "${DRY_RUN:-false}" != true ]; then
    install -d -m 0755 "$(dirname "$(agent_tmp_sweep_script)")" "$(agent_tmp_sweep_systemd_dir)"
  fi
  write_file "$(agent_tmp_sweep_script)" "$(<"$SCRIPT_DIR/scripts/agent-tmp-sweep.py")"
  write_file "$(agent_tmp_sweep_systemd_dir)/wp-coding-agents-tmp-sweep.service" "$service"
  write_file "$(agent_tmp_sweep_systemd_dir)/wp-coding-agents-tmp-sweep.timer" "$(agent_tmp_sweep_render_timer)"
  [ "${DRY_RUN:-false}" = true ] && return 0
  chown root:root "$(agent_tmp_sweep_script)" "$(agent_tmp_sweep_systemd_dir)"/wp-coding-agents-tmp-sweep.{service,timer}
  chmod 0644 "$(agent_tmp_sweep_script)" "$(agent_tmp_sweep_systemd_dir)"/wp-coding-agents-tmp-sweep.{service,timer}
  systemctl daemon-reload
  systemctl enable --now wp-coding-agents-tmp-sweep.timer
}

bridge_service_adapter_apply_agent_tmpdir() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "Skipping agent TMPDIR because upgrade is running non-root"
    return 0
  fi
  write_file "$(agent_tmpdir_tmpfiles_conf)" "$(agent_tmpdir_render_tmpfiles)"
  agent_tmp_sweep_install || return $?
  [ "${DRY_RUN:-false}" = true ] && return 0
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create "$(agent_tmpdir_tmpfiles_conf)"
  else
    install -d -m 0700 -o "$SERVICE_USER" "$AGENT_TMPDIR"
  fi
}

bridge_service_adapter_verify_agent_tmpdir() {
  [ "${DRY_RUN:-false}" = true ] || [ -d "$AGENT_TMPDIR" ]
}

bridge_service_adapter_apply_bridge() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  if [ "$BRIDGE_SERVICE_ADAPTER_OPERATION" = "$INSTALLATION_OPERATION_SETUP" ]; then
    bridge_install || return $?
    declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
    return
  fi
  bridge_sync_config || return $?
  if [ "${LOCAL_MODE:-false}" = true ]; then
    if [ "${PLATFORM:-}" = mac ] && bridge_has_hook update_launchd; then
      bridge_update_launchd || return $?
    fi
    declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
    return 0
  elif [ "${EUID:-$(id -u)}" -eq 0 ]; then
    bridge_update_systemd || return $?
  else
    warn "Skipping chat bridge unit refresh because upgrade is running non-root"
  fi
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

bridge_service_adapter_apply_wordpress_service() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  wordpress_service_reconcile || return $?
  if [ "${DRY_RUN:-false}" != true ] && [ "${LOCAL_MODE:-false}" = true ] && [ "${PLATFORM:-}" = mac ]; then
    reconciler_adapter_changed
  fi
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

bridge_service_adapter_apply_datamachine_worker() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  datamachine_worker_reconcile || return $?
  [ "${DRY_RUN:-false}" = true ] || reconciler_adapter_changed
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

bridge_service_adapter_apply_homeboy_daemon() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "Skipping Homeboy daemon unit because upgrade is running non-root"
    return 0
  fi
  homeboy_daemon_service_reconcile || return $?
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

bridge_service_adapter_verify_homeboy_daemon() {
  homeboy_daemon_service_verify
}
