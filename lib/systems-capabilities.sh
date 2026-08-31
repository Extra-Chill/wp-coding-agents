#!/bin/bash
# Durable, opt-in host policy for managed VPS installs.

SYSTEMS_CAPABILITIES_PROFILE_ROOT="${SYSTEMS_CAPABILITIES_PROFILE_ROOT:-/etc/wp-coding-agents/systems-capabilities}"
SYSTEMS_CAPABILITIES_BIN_DIR="${SYSTEMS_CAPABILITIES_BIN_DIR:-/usr/local/bin}"
SYSTEMS_CAPABILITIES_LIB_DIR="${SYSTEMS_CAPABILITIES_LIB_DIR:-/usr/local/lib/wp-coding-agents}"
SYSTEMS_CAPABILITIES_JOURNALD_FILE="${SYSTEMS_CAPABILITIES_JOURNALD_FILE:-/etc/systemd/journald.conf.d/wp-coding-agents.conf}"
SYSTEMS_CAPABILITIES_LOGROTATE_DIR="${SYSTEMS_CAPABILITIES_LOGROTATE_DIR:-/etc/logrotate.d}"
SYSTEMS_CAPABILITIES_SYSTEMD_DIR="${SYSTEMS_CAPABILITIES_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMS_CAPABILITIES_SUDOERS_DIR="${SYSTEMS_CAPABILITIES_SUDOERS_DIR:-/etc/sudoers.d}"

systems_capabilities_profile_name() { printf '%s' "$(basename "$SITE_PATH")"; }
systems_capabilities_profile_key() {
  local name canonical digest
  name="$(systems_capabilities_profile_name | tr -c 'A-Za-z0-9_-' '-')"
  canonical="$(cd "$SITE_PATH" 2>/dev/null && pwd -P || printf '%s' "$SITE_PATH")"
  digest="$(printf '%s' "$canonical" | sha256sum | cut -c1-12)"
  printf '%s-%s' "$name" "$digest"
}
systems_capabilities_profile_file() { printf '%s/%s.json' "$SYSTEMS_CAPABILITIES_PROFILE_ROOT" "$(systems_capabilities_profile_key)"; }
systems_capabilities_logrotate_file() { printf '%s/wp-coding-agents-%s-debug-log' "$SYSTEMS_CAPABILITIES_LOGROTATE_DIR" "$(systems_capabilities_profile_key)"; }
systems_capabilities_logrotate_timer_file() { printf '%s/logrotate.timer.d/wp-coding-agents.conf' "$SYSTEMS_CAPABILITIES_SYSTEMD_DIR"; }
systems_capabilities_sudoers_file() { printf '%s/wp-coding-agents-process-inspect-%s' "$SYSTEMS_CAPABILITIES_SUDOERS_DIR" "$(systems_capabilities_profile_key)"; }

systems_capabilities_workspace_roots() {
  local roots="${SYSTEMS_CAPABILITIES_WORKSPACE_ROOTS:-${DM_WORKSPACE_DIR:-}}"
  printf '%s' "$roots" | tr ':' '\n' | sed '/^$/d'
}

systems_capabilities_enabled() { [ "${SYSTEMS_CAPABILITIES_PROFILE:-}" = "managed-vps" ]; }

systems_capabilities_validate_profile() {
  case "${SYSTEMS_CAPABILITIES_PROFILE:-}" in
    ""|managed-vps) ;;
    *) error "Unknown systems capability profile: $SYSTEMS_CAPABILITIES_PROFILE (supported: managed-vps)" ;;
  esac
  if [ "${SYSTEMS_CAPABILITIES_PROFILE:-}" = "managed-vps" ] && [ "${LOCAL_MODE:-false}" = true ]; then
    error "The managed-vps systems capability profile requires a colocated VPS install"
  fi
}

systems_capabilities_resolve_profile() {
  [ -n "${SYSTEMS_CAPABILITIES_PROFILE:-}" ] && return 0
  if [ -f "$(systems_capabilities_profile_file)" ] && \
    grep -q '"profile":"managed-vps"' "$(systems_capabilities_profile_file)" 2>/dev/null; then
    SYSTEMS_CAPABILITIES_PROFILE="managed-vps"
  fi
}

systems_capabilities_profile_content() {
  local log="$SITE_PATH/wp-content/debug.log" roots_json adapter logrotate timer_dropin
  roots_json="$(systems_capabilities_workspace_roots | python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.strip()]))')"
  adapter="$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect"
  logrotate="$(systems_capabilities_logrotate_file)"
  timer_dropin="$(systems_capabilities_logrotate_timer_file)"
  python3 -c 'import json,sys; print(json.dumps({"profile":"managed-vps","debug_log":sys.argv[1],"workspace_roots":json.loads(sys.argv[2]),"logrotate":{"config":sys.argv[5],"timer":"logrotate.timer","timer_dropin":sys.argv[6],"schedule":"*:0/5"},"process_inspection":{"adapter":sys.argv[3],"invocation":"printf candidate-path | sudo -n " + sys.argv[3] + " " + sys.argv[4],"stdin":"one absolute candidate path","output":"JSON process references"}}, separators=(",",":")))' "$log" "$roots_json" "$adapter" "$(systems_capabilities_profile_file)" "$logrotate" "$timer_dropin"
}

systems_capabilities_logrotate_content() {
  cat <<EOF
$SITE_PATH/wp-content/debug.log {
    daily
    maxsize 100M
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    su www-data www-data
    create 0640 www-data www-data
}
EOF
}

systems_capabilities_journald_content() {
  cat <<'EOF'
[Journal]
SystemMaxUse=1G
EOF
}

systems_capabilities_logrotate_timer_content() {
  cat <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*:0/5
AccuracySec=1min
RandomizedDelaySec=0
Persistent=true
EOF
}

systems_capabilities_sudoers_content() {
  printf '%s ALL=(root) NOPASSWD: %s %s\n' "$SERVICE_USER" "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" "$(systems_capabilities_profile_file)"
}

systems_capabilities_process_probe_argv() {
  python3 -c 'import json,sys; print(json.dumps(["sudo", "-n", sys.argv[1], sys.argv[2]]))' "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" "$(systems_capabilities_profile_file)"
}

systems_capabilities_write_exact() {
  local file="$1" content="$2" mode="$3" group="${4:-root}"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install managed systems capability artifact: $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s' "$content" > "$file"
  chown "root:$group" "$file"
  chmod "$mode" "$file"
}

systems_capabilities_install_sudoers() {
  local file="$1" content="$2" tmp
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would validate and install managed sudoers policy: $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")"
  printf '%s' "$content" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    error "Generated systems capability sudoers policy is invalid: $file"
  fi
  chown root:root "$tmp"
  chmod 0440 "$tmp"
  mv "$tmp" "$file"
}

systems_capabilities_drift() {
  local file="$1" content="$2" mode="${3#0}" group="${4:-root}"
  [ -f "$file" ] && [ "$(cat "$file")" = "$content" ] && \
    [ "$(stat -c '%U:%G:%a' "$file" 2>/dev/null || true)" = "root:$group:$mode" ]
}

systems_capabilities_report_root_repair() {
  printf '{"status":"root_repair_required","profile":"managed-vps","repair_command":"sudo ./upgrade.sh --systems-capabilities managed-vps --wp-path %s"}\n' "$SITE_PATH"
}

systems_capabilities_status() {
  local profile logrotate logrotate_timer adapter sudoers journal
  profile="$(systems_capabilities_profile_file)"
  logrotate="$(systems_capabilities_logrotate_file)"
  logrotate_timer="$(systems_capabilities_logrotate_timer_file)"
  adapter="$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect"
  sudoers="$(systems_capabilities_sudoers_file)"
  journal="$SYSTEMS_CAPABILITIES_JOURNALD_FILE"
  local missing=()
  systems_capabilities_drift "$profile" "$(systems_capabilities_profile_content)" 0640 "$SERVICE_USER" || missing+=(profile)
  systems_capabilities_drift "$logrotate" "$(systems_capabilities_logrotate_content)" 0644 || missing+=(logrotate)
  systems_capabilities_drift "$logrotate_timer" "$(systems_capabilities_logrotate_timer_content)" 0644 || missing+=(logrotate_timer)
  systems_capabilities_drift "$journal" "$(systems_capabilities_journald_content)" 0644 || missing+=(journald)
  systems_capabilities_drift "$adapter" "$(cat "$SCRIPT_DIR/scripts/process-inspect.py")" 0755 || missing+=(adapter)
  systems_capabilities_drift "$sudoers" "$(systems_capabilities_sudoers_content)" 0440 || missing+=(sudoers)
  if [ ${#missing[@]} -eq 0 ]; then
    printf '{"status":"healthy","profile":"managed-vps"}\n'
  else
    printf '{"status":"drift","profile":"managed-vps","missing_or_drifted":['
    printf '"%s",' "${missing[@]}" | sed 's/,$//'
    printf ']}\n'
    return 1
  fi
}

systems_capabilities_apply() {
  systems_capabilities_validate_profile
  [ "$LOCAL_MODE" = false ] || return 0
  systems_capabilities_enabled || return 0
  if [ "$DRY_RUN" = true ]; then
    log "Dry-run: provisioning managed VPS systems capabilities..."
    systems_capabilities_write_exact "$(systems_capabilities_profile_file)" "$(systems_capabilities_profile_content)" 0640 "$SERVICE_USER"
    systems_capabilities_write_exact "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" "$(systems_capabilities_journald_content)" 0644
    systems_capabilities_write_exact "$(systems_capabilities_logrotate_file)" "$(systems_capabilities_logrotate_content)" 0644
    systems_capabilities_write_exact "$(systems_capabilities_logrotate_timer_file)" "$(systems_capabilities_logrotate_timer_content)" 0644
    systems_capabilities_write_exact "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" "$(cat "$SCRIPT_DIR/scripts/process-inspect.py")" 0755
    systems_capabilities_write_exact "$SYSTEMS_CAPABILITIES_BIN_DIR/wp-coding-agents-systems-capabilities" "$(cat "$SCRIPT_DIR/scripts/systems-capabilities-status.py")" 0755
    systems_capabilities_install_sudoers "$(systems_capabilities_sudoers_file)" "$(systems_capabilities_sudoers_content)"
    return 0
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    systems_capabilities_report_root_repair
    return 0
  fi
  log "Provisioning managed VPS systems capabilities..."
  local journald_changed=false logrotate_timer_changed=false
  systems_capabilities_drift "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" "$(systems_capabilities_journald_content)" 0644 || journald_changed=true
  systems_capabilities_drift "$(systems_capabilities_logrotate_timer_file)" "$(systems_capabilities_logrotate_timer_content)" 0644 || logrotate_timer_changed=true
  systems_capabilities_write_exact "$(systems_capabilities_profile_file)" "$(systems_capabilities_profile_content)" 0640 "$SERVICE_USER"
  systems_capabilities_write_exact "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" "$(systems_capabilities_journald_content)" 0644
  systems_capabilities_write_exact "$(systems_capabilities_logrotate_file)" "$(systems_capabilities_logrotate_content)" 0644
  systems_capabilities_write_exact "$(systems_capabilities_logrotate_timer_file)" "$(systems_capabilities_logrotate_timer_content)" 0644
  systems_capabilities_write_exact "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" "$(cat "$SCRIPT_DIR/scripts/process-inspect.py")" 0755
  systems_capabilities_write_exact "$SYSTEMS_CAPABILITIES_BIN_DIR/wp-coding-agents-systems-capabilities" "$(cat "$SCRIPT_DIR/scripts/systems-capabilities-status.py")" 0755
  systems_capabilities_install_sudoers "$(systems_capabilities_sudoers_file)" "$(systems_capabilities_sudoers_content)"
  if [ "$journald_changed" = true ]; then
    systemctl restart systemd-journald
  fi
  if [ "$logrotate_timer_changed" = true ]; then
    systemctl daemon-reload
  fi
  systemctl enable --now logrotate.timer
  if [ "$logrotate_timer_changed" = true ]; then
    systemctl restart logrotate.timer
  fi
  systems_capabilities_status
}
