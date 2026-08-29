#!/bin/bash
# Optional Data Machine queue worker. This service drains Data Machine work; it
# does not act as a generic WP-Cron heartbeat.

DATAMACHINE_WORKER_TRANSPORT=()

datamachine_worker_systemd_units() { echo "datamachine-worker.service datamachine-worker.timer"; }
datamachine_worker_launchd_label() { echo "com.wp.datamachine-worker"; }
datamachine_worker_state_file() { printf '%s/.config/wp-coding-agents/datamachine-worker.enabled' "$SERVICE_HOME"; }
datamachine_worker_systemd_dir() { printf '%s' "${DATAMACHINE_WORKER_SYSTEMD_DIR:-/etc/systemd/system}"; }
datamachine_worker_launchd_dir() { printf '%s' "${DATAMACHINE_WORKER_LAUNCHD_DIR:-$SERVICE_HOME/Library/LaunchAgents}"; }

datamachine_worker_desired_state() {
  local requested="${DATAMACHINE_WORKER_REQUEST:-${WP_CODING_AGENTS_DATAMACHINE_WORKER_ENABLED:-}}"
  case "$requested" in
    1|true|enabled) printf 'enabled\n'; return 0 ;;
    0|false|disabled) printf 'disabled\n'; return 0 ;;
    "") ;;
    *) error "Unknown Data Machine worker state: $requested (supported: enabled, disabled)" ;;
  esac

  if [ -f "$(datamachine_worker_state_file)" ]; then
    printf 'enabled\n'
  else
    printf 'disabled\n'
  fi
}

datamachine_worker_record_state() {
  local state="$1" file
  file="$(datamachine_worker_state_file)"
  if [ "$state" = "enabled" ]; then
    run_cmd mkdir -p "${file%/*}"
    write_file "$file" "enabled"
    return
  fi
  run_cmd rm -f "$file"
}

_datamachine_worker_shell_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

_datamachine_worker_xml_text() {
  local value="$1"
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  printf '%s' "$value"
}

datamachine_worker_prepare_command() {
  local executable
  wp_cli_transport_ensure
  DATAMACHINE_WORKER_TRANSPORT=("${WP_CLI_TRANSPORT[@]}")
  executable="$(command -v "${WP_CLI_TRANSPORT[0]}" 2>/dev/null || true)"
  if [ -n "$executable" ]; then
    DATAMACHINE_WORKER_TRANSPORT[0]="$executable"
  fi
}

_datamachine_worker_command() {
  local command="" argument quoted
  [ "${#DATAMACHINE_WORKER_TRANSPORT[@]}" -gt 0 ] || datamachine_worker_prepare_command || return 1
  for argument in "${DATAMACHINE_WORKER_TRANSPORT[@]}"; do
    printf -v quoted '%q' "$argument"
    command="${command:+$command }$quoted"
  done
  printf 'cd "%s" && %s datamachine worker run --once' "$SITE_PATH" "$command"
}

datamachine_worker_render_systemd_service() {
  cat <<EOF
[Unit]
Description=Optional Data Machine queue worker (wp-coding-agents)
After=network.target

[Service]
Type=oneshot
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/sh -lc '$(_datamachine_worker_command)'
EOF
}

datamachine_worker_render_systemd_timer() {
  cat <<'EOF'
[Unit]
Description=Run the optional Data Machine queue worker every two minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=datamachine-worker.service

[Install]
WantedBy=timers.target
EOF
}

datamachine_worker_render_launchd() {
  local label="$1"
  local log_dir="$SERVICE_HOME/.datamachine"
  local command_xml label_xml log_dir_xml service_home_xml site_path_xml
  [ "$label" = "com.wp.datamachine-worker" ] || return 1
  command_xml="$(_datamachine_worker_xml_text "$(_datamachine_worker_command)")"
  label_xml="$(_datamachine_worker_xml_text "$label")"
  log_dir_xml="$(_datamachine_worker_xml_text "$log_dir")"
  service_home_xml="$(_datamachine_worker_xml_text "$SERVICE_HOME")"
  site_path_xml="$(_datamachine_worker_xml_text "$SITE_PATH")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label_xml</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-lc</string>
        <string>$command_xml</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$site_path_xml</string>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>StandardOutPath</key>
    <string>$log_dir_xml/datamachine-worker.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir_xml/datamachine-worker.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$service_home_xml</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF
}

datamachine_worker_install() {
  datamachine_worker_prepare_command || return 1

  if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    local label plist_dir plist
    label="$(datamachine_worker_launchd_label)"
    plist_dir="$(datamachine_worker_launchd_dir)"
    plist="$plist_dir/$label.plist"
    run_cmd mkdir -p "$plist_dir" "$SERVICE_HOME/.datamachine"
    write_file "$plist" "$(datamachine_worker_render_launchd "$label")"
    if [ "$DRY_RUN" = false ]; then
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
    log "Data Machine worker: $label"
    return
  fi

  if [ "$LOCAL_MODE" = true ]; then
    warn "Data Machine worker requires launchd or systemd; local manual mode is not supervised."
    return
  fi

  write_file "$(datamachine_worker_systemd_dir)/datamachine-worker.service" "$(datamachine_worker_render_systemd_service)"
  write_file "$(datamachine_worker_systemd_dir)/datamachine-worker.timer" "$(datamachine_worker_render_systemd_timer)"
  if [ "$DRY_RUN" = false ]; then
    systemctl daemon-reload
    systemctl enable --now datamachine-worker.timer
  fi
}

datamachine_worker_update() {
  datamachine_worker_prepare_command || return 1

  if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    local label plist
    label="$(datamachine_worker_launchd_label)"
    plist="$(datamachine_worker_launchd_dir)/$label.plist"
    if [ ! -f "$plist" ]; then
      datamachine_worker_install
      return
    fi
    write_file "$plist" "$(datamachine_worker_render_launchd "$label")"
    if [ "$DRY_RUN" = false ]; then
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
    return
  fi
  [ "$LOCAL_MODE" = true ] && return 0
  local systemd_dir
  systemd_dir="$(datamachine_worker_systemd_dir)"
  if [ ! -f "$systemd_dir/datamachine-worker.service" ] || [ ! -f "$systemd_dir/datamachine-worker.timer" ]; then
    datamachine_worker_install
    return
  fi
  _smart_update_systemd_unit "$systemd_dir/datamachine-worker.service" "$(datamachine_worker_render_systemd_service)" datamachine-worker.service
  _smart_update_systemd_unit "$systemd_dir/datamachine-worker.timer" "$(datamachine_worker_render_systemd_timer)" datamachine-worker.timer
  if [ "$DRY_RUN" = false ]; then
    systemctl restart datamachine-worker.timer
  fi
}

datamachine_worker_remove() {
  if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    local label plist
    label="$(datamachine_worker_launchd_label)"
    plist="$(datamachine_worker_launchd_dir)/$label.plist"
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would unload and remove $plist"
    else
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      rm -f "$plist"
    fi
    log "Data Machine worker: disabled"
    return
  fi

  [ "$LOCAL_MODE" = true ] && return 0
  local systemd_dir service timer
  systemd_dir="$(datamachine_worker_systemd_dir)"
  service="$systemd_dir/datamachine-worker.service"
  timer="$systemd_dir/datamachine-worker.timer"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would disable and remove datamachine-worker.timer"
  else
    systemctl disable --now datamachine-worker.timer 2>/dev/null || true
    rm -f "$service" "$timer"
    systemctl daemon-reload
  fi
  log "Data Machine worker: disabled"
}

datamachine_worker_reconcile() {
  local state
  state="$(datamachine_worker_desired_state)"
  datamachine_worker_record_state "$state"
  if [ "$state" = "enabled" ]; then
    datamachine_worker_update
  else
    datamachine_worker_remove
  fi
}
