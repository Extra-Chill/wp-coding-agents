#!/bin/bash
# Data Machine queue heartbeat service. Runs a bounded worker pass regularly so
# headless WordPress installs do not depend on HTTP-triggered WP-Cron traffic.

datamachine_worker_systemd_units() { echo "datamachine-worker.service datamachine-worker.timer"; }
datamachine_worker_launchd_label() { echo "com.wp.datamachine-worker"; }

_datamachine_worker_shell_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

_datamachine_worker_uses_studio() {
  [ "${WP_CMD:-wp}" = "studio wp" ]
}

_datamachine_worker_resolve_studio_bin() {
  local candidate="${STUDIO_BIN:-}"
  local directory

  if [ -z "$candidate" ]; then
    candidate="$(command -v studio 2>/dev/null || true)"
  fi

  if [ -z "$candidate" ] || [ ! -f "$candidate" ] || [ ! -x "$candidate" ]; then
    printf 'Data Machine worker requires an executable Studio CLI; install it or ensure studio is on PATH during setup/upgrade.\n' >&2
    return 1
  fi

  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      directory="$(cd "$(dirname "$candidate")" && pwd)" || return 1
      printf '%s/%s\n' "$directory" "$(basename "$candidate")"
      ;;
  esac
}

datamachine_worker_prepare_command() {
  _datamachine_worker_uses_studio || return 0
  STUDIO_BIN="$(_datamachine_worker_resolve_studio_bin)" || return 1
  export STUDIO_BIN
}

_datamachine_worker_command() {
  if _datamachine_worker_uses_studio; then
    [ -n "${STUDIO_BIN:-}" ] || datamachine_worker_prepare_command || return 1
    printf 'cd "%s" && %s wp datamachine worker run --once' "$SITE_PATH" "$(_datamachine_worker_shell_quote "$STUDIO_BIN")"
    return
  fi

  printf '%s' "cd \"$SITE_PATH\" && $WP_CMD datamachine worker run --once"
}

datamachine_worker_render_systemd_service() {
  cat <<EOF
[Unit]
Description=Data Machine queue worker heartbeat (wp-coding-agents)
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
Description=Run Data Machine queue worker heartbeat every two minutes

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
  [ "$label" = "com.wp.datamachine-worker" ] || return 1
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-lc</string>
        <string>$(_datamachine_worker_command)</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>StandardOutPath</key>
    <string>$log_dir/datamachine-worker.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/datamachine-worker.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>
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
    plist_dir="$HOME/Library/LaunchAgents"
    plist="$plist_dir/$label.plist"
    run_cmd mkdir -p "$plist_dir" "$SERVICE_HOME/.datamachine"
    write_file "$plist" "$(datamachine_worker_render_launchd "$label")"
    if [ "$DRY_RUN" = false ]; then
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
    log "Data Machine worker heartbeat: $label"
    return
  fi

  if [ "$LOCAL_MODE" = true ]; then
    warn "Data Machine worker heartbeat requires launchd or systemd; local manual mode is not supervised."
    return
  fi

  write_file "/etc/systemd/system/datamachine-worker.service" "$(datamachine_worker_render_systemd_service)"
  write_file "/etc/systemd/system/datamachine-worker.timer" "$(datamachine_worker_render_systemd_timer)"
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
    plist="$HOME/Library/LaunchAgents/$label.plist"
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
  if [ ! -f /etc/systemd/system/datamachine-worker.service ] || [ ! -f /etc/systemd/system/datamachine-worker.timer ]; then
    datamachine_worker_install
    return
  fi
  _smart_update_systemd_unit /etc/systemd/system/datamachine-worker.service "$(datamachine_worker_render_systemd_service)" datamachine-worker.service
  _smart_update_systemd_unit /etc/systemd/system/datamachine-worker.timer "$(datamachine_worker_render_systemd_timer)" datamachine-worker.timer
  if [ "$DRY_RUN" = false ]; then
    systemctl restart datamachine-worker.timer
  fi
}
