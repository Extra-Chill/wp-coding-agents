#!/bin/bash
# Optional local WordPress HTTP service backed by WP-CLI's built-in server.

wordpress_service_site_id() {
  python3 - "$SITE_PATH" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])
PY
}

wordpress_service_label() { printf 'com.wp.wordpress.%s' "$(wordpress_service_site_id)"; }
wordpress_service_launchd_dir() { printf '%s' "${WORDPRESS_SERVICE_LAUNCHD_DIR:-$SERVICE_HOME/Library/LaunchAgents}"; }
wordpress_service_state_file() { printf '%s/.config/wp-coding-agents/wordpress-service/%s.conf' "$SERVICE_HOME" "$(wordpress_service_site_id)"; }

wordpress_service_desired_state() {
  case "${WORDPRESS_SERVICE_REQUEST:-}" in
    enabled|true|1) printf 'enabled\n'; return ;;
    disabled|false|0) printf 'disabled\n'; return ;;
    "") ;;
    *) error "Unknown local WordPress service state: $WORDPRESS_SERVICE_REQUEST" ;;
  esac
  [ -f "$(wordpress_service_state_file)" ] && printf 'enabled\n' || printf 'disabled\n'
}

wordpress_service_resolve_settings() {
  local state_file key value
  state_file="$(wordpress_service_state_file)"
  if [ -f "$state_file" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        host) WORDPRESS_SERVICE_HOST="${WORDPRESS_SERVICE_HOST:-$value}" ;;
        port) WORDPRESS_SERVICE_PORT="${WORDPRESS_SERVICE_PORT:-$value}" ;;
      esac
    done < "$state_file"
  fi

  WORDPRESS_SERVICE_HOST="${WORDPRESS_SERVICE_HOST:-127.0.0.1}"
  WORDPRESS_SERVICE_PORT="${WORDPRESS_SERVICE_PORT:-8080}"
  [[ "$WORDPRESS_SERVICE_PORT" =~ ^[0-9]+$ ]] || error "WordPress service port must be an integer"
  [ "$WORDPRESS_SERVICE_PORT" -ge 1 ] && [ "$WORDPRESS_SERVICE_PORT" -le 65535 ] || error "WordPress service port must be between 1 and 65535"
  [[ "$WORDPRESS_SERVICE_HOST" =~ ^[A-Za-z0-9.:_-]+$ ]] || error "WordPress service host contains unsupported characters"
}

wordpress_service_record_state() {
  local state="$1" file
  file="$(wordpress_service_state_file)"
  if [ "$state" = enabled ]; then
    run_cmd mkdir -p "${file%/*}"
    write_file "$file" "host=$WORDPRESS_SERVICE_HOST
port=$WORDPRESS_SERVICE_PORT"
  else
    run_cmd rm -f "$file"
  fi
}

wordpress_service_prepare_command() {
  local executable php_executable
  wp_cli_transport_ensure
  [ "${#WP_CLI_TRANSPORT[@]}" -eq 1 ] || error "The local WordPress service requires a direct wp transport"
  executable="$(command -v "${WP_CLI_TRANSPORT[0]}" 2>/dev/null || true)"
  [ -n "$executable" ] || error "The local WordPress service requires WP-CLI on PATH"
  php_executable="$(command -v php 2>/dev/null || true)"
  [ -n "$php_executable" ] || error "The local WordPress service requires PHP on PATH"
  WORDPRESS_SERVICE_WP="$executable"
  WORDPRESS_SERVICE_PHP="$php_executable"
}

_wordpress_service_xml_text() {
  local value="$1"
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  printf '%s' "$value"
}

wordpress_service_render_launchd() {
  local label="$1" log_dir="$SERVICE_HOME/.wp-coding-agents/logs"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(_wordpress_service_xml_text "$label")</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(_wordpress_service_xml_text "$WORDPRESS_SERVICE_PHP")</string>
        <string>$(_wordpress_service_xml_text "$WORDPRESS_SERVICE_WP")</string>
        <string>server</string>
        <string>--path=$(_wordpress_service_xml_text "$SITE_PATH")</string>
        <string>--host=$(_wordpress_service_xml_text "$WORDPRESS_SERVICE_HOST")</string>
        <string>--port=$WORDPRESS_SERVICE_PORT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(_wordpress_service_xml_text "$SITE_PATH")</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(_wordpress_service_xml_text "$log_dir/wordpress-service.log")</string>
    <key>StandardErrorPath</key>
    <string>$(_wordpress_service_xml_text "$log_dir/wordpress-service.error.log")</string>
</dict>
</plist>
EOF
}

wordpress_service_update() {
  local label plist_dir plist
  wordpress_service_resolve_settings
  wordpress_service_prepare_command
  label="$(wordpress_service_label)"
  plist_dir="$(wordpress_service_launchd_dir)"
  plist="$plist_dir/$label.plist"
  run_cmd mkdir -p "$plist_dir" "$SERVICE_HOME/.wp-coding-agents/logs"
  write_file "$plist" "$(wordpress_service_render_launchd "$label")"
  wordpress_service_record_state enabled
  if [ "$DRY_RUN" = false ]; then
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
  fi
  log "Local WordPress service: $label ($WORDPRESS_SERVICE_HOST:$WORDPRESS_SERVICE_PORT)"
}

wordpress_service_remove() {
  local plist
  plist="$(wordpress_service_launchd_dir)/$(wordpress_service_label).plist"
  if [ "$DRY_RUN" = false ]; then
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  fi
  run_cmd rm -f "$plist"
  wordpress_service_record_state disabled
}

wordpress_service_reconcile() {
  local state
  state="$(wordpress_service_desired_state)"
  if [ "$state" = enabled ]; then
    [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = mac ] || error "The managed local WordPress service currently requires macOS local mode"
    wordpress_service_update
  else
    [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = mac ] && wordpress_service_remove
  fi
}
