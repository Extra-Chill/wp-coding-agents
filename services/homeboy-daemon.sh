#!/bin/bash
# Supervised Homeboy daemon (systemd, managed non-root installs).
#
# Without this unit the daemon is spawned on demand by whichever Homeboy
# command first needs it. On a VPS that is almost always an agent shell inside
# the chat bridge's systemd unit, so the daemon lives in the bridge's cgroup
# and dies, with any in-flight cook, on every bridge restart, upgrade, or
# migration (#659).
#
# The unit runs `homeboy daemon serve` in its own cgroup. Homeboy's exclusive
# daemon-owner lock keeps it the single owner: commands find the live daemon
# instead of spawning one, and if some other launcher holds the lock (an older
# on-demand daemon, or one started during a Homeboy self-upgrade), the unit
# retries until that daemon exits and then takes ownership. Installs converge
# into the unit rather than racing it.

homeboy_daemon_unit_name() { echo "homeboy-daemon.service"; }
homeboy_daemon_systemd_dir() { printf '%s' "${HOMEBOY_DAEMON_SYSTEMD_DIR:-/etc/systemd/system}"; }
homeboy_daemon_unit_path() { printf '%s/%s' "$(homeboy_daemon_systemd_dir)" "$(homeboy_daemon_unit_name)"; }

# Local Cooks run Pi under this unit, outside any Roadie session (#870). The
# chat bridge can register a durable pool client for the daemon; its key and
# Pi agent dir live in this root-owned 0600 EnvironmentFile, never in the unit.
homeboy_daemon_pool_client_name() { printf '%s' "${HOMEBOY_DAEMON_POOL_CLIENT:-homeboy-daemon}"; }
homeboy_daemon_pi_env_file() { printf '%s' "${HOMEBOY_DAEMON_PI_ENV_FILE:-/etc/wp-coding-agents/homeboy/pi.env}"; }

# Succeeds when the loaded bridge offers the daemon a pool client.
homeboy_daemon_pool_client_applicable() {
  declare -F bridge_pool_client_applicable >/dev/null 2>&1 || return 1
  bridge_pool_client_applicable
}

# The unit only applies where wp-coding-agents owns a service-owned Homeboy
# binary under systemd: managed VPS installs, not local or external-WordPress
# installs, and only once that binary exists.
homeboy_daemon_service_applicable() {
  [ "${LOCAL_MODE:-false}" = true ] && return 1
  [ "${EXTERNAL_WORDPRESS:-false}" = true ] && return 1
  homeboy_uses_service_owned_bin || return 1
  [ -x "$(homeboy_service_bin)" ] || return 1
}

homeboy_daemon_render_systemd_service() {
  local resource_policy
  resource_policy="$(agent_systemd_resource_policy)" || return $?
  local bin sender sender_env sender_dir path
  bin="$(homeboy_service_bin)"
  sender=""
  sender_env=""
  sender_dir=""
  if declare -F bridge_session_sender_command >/dev/null 2>&1; then
    sender="$(bridge_session_sender_command)"
    if [ -n "$sender" ]; then
      sender_dir="$(dirname "${sender%% *}")"
      declare -F bridge_session_sender_env >/dev/null 2>&1 && sender_env="$(bridge_session_sender_env)"
    fi
  fi
  path="$(_service_path_value "$(dirname "$bin")" "$sender_dir" "$(_resolve_node_bin_dir "${sender%% *}")")"
  local pi_env=""
  # Optional (-): a missing file leaves Cooks unauthenticated, which verify
  # reports, rather than keeping the daemon itself from starting.
  homeboy_daemon_pool_client_applicable && pi_env="EnvironmentFile=-$(homeboy_daemon_pi_env_file)"
# HOME, PATH, and the session sender can all carry whitespace (operator-set
# paths, or a sender command like "<roadie> send"), so systemd's quoting wraps
# them; assignments that cannot contain whitespace stay simple. The sender's
# own extra Environment= lines arrive pre-formatted from the bridge.
  cat <<EOF
[Unit]
Description=Homeboy daemon (wp-coding-agents)
After=network-online.target
Wants=network-online.target
# Keep retrying while another launcher still owns the daemon lock.
StartLimitIntervalSec=0

[Service]
$resource_policy
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SERVICE_HOME
Environment=$(systemd_quote "HOME=$SERVICE_HOME")$(homeboy_data_dir_systemd_env)
Environment=$(systemd_quote "PATH=$path")
${sender:+Environment=$(systemd_quote "HOMEBOY_SESSION_SEND_COMMAND=$sender")
}${sender_env:+$sender_env
}${pi_env:+$pi_env
}
ExecStart=$bin daemon serve
Restart=always
RestartSec=10
# Workloads the daemon runs are its children; stopping the daemon stops them.
KillMode=control-group
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
}

# Run Homeboy as the service user and print `homeboy daemon status` JSON.
_homeboy_daemon_status_json() {
  local bin output status=0
  bin="$(homeboy_service_bin)"
  output="$(mktemp)"
  if [ "$(id -u)" -eq 0 ]; then
    sudo -n -H -u "$SERVICE_USER" env HOME="$SERVICE_HOME" "$bin" daemon status --output "$output" >/dev/null 2>&1 || status=$?
    # The service user writes the file; root reads it back.
  else
    HOME="$SERVICE_HOME" "$bin" daemon status --output "$output" >/dev/null 2>&1 || status=$?
  fi
  if [ -s "$output" ]; then
    cat "$output"
  fi
  rm -f "$output"
  return "$status"
}

# Field from daemon status: active-jobs count, or running/fresh flags.
_homeboy_daemon_status_field() {
  local field="$1"
  _homeboy_daemon_status_json 2>/dev/null | python3 -c '
import json, sys
field = sys.argv[1]
try:
    data = json.load(sys.stdin).get("data", {})
except Exception:
    print("unknown"); sys.exit(0)
if field == "active_jobs":
    jobs = data.get("active_jobs")
    print(len(jobs) if isinstance(jobs, list) else "unknown")
elif field == "pid":
    print((data.get("daemon") or {}).get("pid") or "")
else:
    value = data.get(field)
    print("unknown" if value is None else str(value).lower())
' "$field"
}

# True when no daemon job is in flight, so stopping or restarting the daemon
# cannot interrupt work. Unknown status is treated as busy.
homeboy_daemon_idle() {
  [ "$(_homeboy_daemon_status_field active_jobs)" = 0 ]
}

# True when the systemd unit's main process is the daemon that owns the lease.
_homeboy_daemon_owned_by_unit() {
  local unit_pid daemon_pid
  unit_pid="$(systemctl show -p MainPID --value "$(homeboy_daemon_unit_name)" 2>/dev/null || true)"
  daemon_pid="$(_homeboy_daemon_status_field pid)"
  [ -n "$unit_pid" ] && [ "$unit_pid" != 0 ] && [ "$unit_pid" = "$daemon_pid" ]
}

_homeboy_daemon_as_service_user() {
  local bin
  bin="$(homeboy_service_bin)"
  if [ "$(id -u)" -eq 0 ]; then
    sudo -n -H -u "$SERVICE_USER" env HOME="$SERVICE_HOME" "$bin" "$@"
  else
    HOME="$SERVICE_HOME" "$bin" "$@"
  fi
}

# Hand an idle daemon started outside the unit over to the unit. A busy one is
# left alone: the unit keeps retrying and takes over when that daemon exits.
homeboy_daemon_adopt_unsupervised() {
  _homeboy_daemon_owned_by_unit && return 0
  [ "$(_homeboy_daemon_status_field running)" = true ] || return 0
  if homeboy_daemon_idle; then
    log "  Homeboy daemon: stopping idle unsupervised daemon so homeboy-daemon.service owns it"
    _homeboy_daemon_as_service_user daemon stop >/dev/null 2>&1 \
      || warn "  Homeboy daemon: could not stop the unsupervised daemon; homeboy-daemon.service will take over when it exits"
  else
    warn "  Homeboy daemon: an unsupervised daemon has jobs in flight; homeboy-daemon.service will take over when it exits"
  fi
}

# After the Homeboy binary changes, restart the supervised daemon onto it, but
# never under in-flight work. A busy daemon keeps serving its jobs; the next
# upgrade, or `systemctl restart homeboy-daemon`, converges it.
homeboy_daemon_converge_binary() {
  _homeboy_daemon_owned_by_unit || return 0
  [ "$(_homeboy_daemon_status_field fresh)" = false ] || return 0
  if homeboy_daemon_idle; then
    log "  Homeboy daemon: restarting onto the installed binary"
    systemctl restart "$(homeboy_daemon_unit_name)"
  else
    warn "  Homeboy daemon: running a replaced binary with jobs in flight; restart homeboy-daemon.service once idle"
  fi
}

# Move Homeboy's data root from the service user's home onto HOMEBOY_DATA_DIR
# before any unit renders it (#710). The legacy path is left as a symlink so
# processes that did not inherit the variable resolve the same store. When the
# move cannot run safely, HOMEBOY_DATA_DIR is cleared for this run so no unit
# is pointed at an empty store; the next upgrade retries.
_homeboy_data_dir_is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

homeboy_data_dir_migrate() {
  [ -n "${HOMEBOY_DATA_DIR:-}" ] || return 0
  local legacy="${SERVICE_HOME:-}/.local/share/homeboy" target="$HOMEBOY_DATA_DIR" unit
  unit="$(homeboy_daemon_unit_name)"

  [ -n "${SERVICE_HOME:-}" ] || return 0
  if [ -L "$legacy" ] || [ ! -e "$legacy" ]; then
    return 0
  fi
  if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    warn "  Homeboy data: both $legacy and $target exist; leaving Homeboy on $legacy"
    HOMEBOY_DATA_DIR=""
    return 0
  fi
  if [ "${DRY_RUN:-false}" = true ]; then
    log "  Homeboy data: would move $legacy to $target"
    HOMEBOY_DATA_DIR=""
    return 0
  fi
  if ! _homeboy_data_dir_is_root; then
    warn "  Homeboy data: moving $legacy to $target requires root; deferred"
    HOMEBOY_DATA_DIR=""
    return 0
  fi
  if [ "$(_homeboy_daemon_status_field running)" = true ] && ! homeboy_daemon_idle; then
    warn "  Homeboy data: daemon has jobs in flight; moving $legacy to $target deferred"
    HOMEBOY_DATA_DIR=""
    return 0
  fi

  systemctl stop "$unit" >/dev/null 2>&1 || true
  if [ -e "$legacy/homeboy.sqlite" ] && fuser "$legacy/homeboy.sqlite" >/dev/null 2>&1; then
    warn "  Homeboy data: $legacy/homeboy.sqlite is still open; move deferred"
    HOMEBOY_DATA_DIR=""
    return 0
  fi

  mkdir -p "$target"
  if ! rsync -aHAX "$legacy/" "$target/"; then
    warn "  Homeboy data: copy to $target failed; leaving Homeboy on $legacy"
    HOMEBOY_DATA_DIR=""
    return 0
  fi
  if [ -e "$target/homeboy.sqlite" ] && \
     [ "$(sqlite3 "$target/homeboy.sqlite" 'PRAGMA integrity_check;' 2>/dev/null)" != ok ]; then
    warn "  Homeboy data: copied store failed integrity_check; leaving Homeboy on $legacy"
    HOMEBOY_DATA_DIR=""
    return 0
  fi
  chown -R "$SERVICE_USER:$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")" "$target" 2>/dev/null || true
  rm -rf "$legacy"
  ln -s "$target" "$legacy"
  chown -h "$SERVICE_USER" "$legacy" 2>/dev/null || true
  log "  Homeboy data: moved $legacy to $target"
}

homeboy_daemon_service_reconcile() {
  homeboy_daemon_service_applicable || return 0
  local unit unit_path rendered changed=false
  unit="$(homeboy_daemon_unit_name)"
  unit_path="$(homeboy_daemon_unit_path)"

  BRIDGE_POOL_CLIENT_ENV_CHANGED=false
  if homeboy_daemon_pool_client_applicable; then
    # A failed registration is reported as pending; the daemon still runs.
    bridge_pool_client_reconcile "$(homeboy_daemon_pool_client_name)" "$(homeboy_daemon_pi_env_file)" || true
  fi

  if [ ! -f "$unit_path" ]; then
    write_file "$unit_path" "$(homeboy_daemon_render_systemd_service)"
    [ "${DRY_RUN:-false}" = true ] && return 0
    systemctl daemon-reload
    homeboy_daemon_adopt_unsupervised
    systemctl enable --now "$unit"
    log "Homeboy daemon: supervised by $unit"
    return 0
  fi

  rendered="$(homeboy_daemon_render_systemd_service)"
  cmp -s <(printf '%s\n' "$rendered") "$unit_path" || changed=true
  # A new key or agent dir only reaches the daemon through a restart.
  [ "${BRIDGE_POOL_CLIENT_ENV_CHANGED:-false}" = true ] && changed=true
  _smart_update_systemd_unit "$unit_path" "$rendered" "$unit"
  [ "${DRY_RUN:-false}" = true ] && return 0
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$unit"; then
    homeboy_daemon_adopt_unsupervised
    systemctl start "$unit"
    return 0
  fi
  if [ "$changed" = true ]; then
    if homeboy_daemon_idle; then
      log "  Homeboy daemon: restarting idle daemon onto the updated unit"
      systemctl restart "$unit"
    else
      warn "  Homeboy daemon: updated unit will take effect after restart; daemon has jobs in flight"
    fi
    return 0
  fi
  homeboy_daemon_converge_binary
}

homeboy_daemon_service_verify() {
  homeboy_daemon_service_applicable || return 0
  [ -f "$(homeboy_daemon_unit_path)" ]
}

# homeboy_daemon_pi_route_status <unit_path>
#
# Report whether local Cooks under the daemon can authenticate to the Roadie
# pool. Prints one line and returns 0 when the route is authenticated, 2 when
# the unit has no pool client route to check, and 1 when it is
# unauthenticated ("local Cook provider route unauthenticated: <why>").
homeboy_daemon_pi_route_status() {
  local unit_path="$1" env_file key agent_dir mode
  [ -f "$unit_path" ] || { echo "no Homeboy daemon unit"; return 2; }
  env_file="$(sed -n 's/^EnvironmentFile=-\{0,1\}//p' "$unit_path" | grep -F '/pi.env' | tail -n 1)"
  if [ -z "$env_file" ]; then
    echo "local Cook provider route unauthenticated: $(basename "$unit_path") loads no Roadie pool client EnvironmentFile"
    return 1
  fi
  if [ ! -e "$env_file" ]; then
    echo "local Cook provider route unauthenticated: $env_file is missing"
    return 1
  fi
  if [ ! -r "$env_file" ]; then
    echo "cannot read $env_file (run as root)"
    return 2
  fi
  mode="$(file_mode "$env_file" 2>/dev/null || true)"
  if [ "$mode" != 600 ]; then
    echo "local Cook provider route exposed: $env_file is mode $mode, expected 600"
    return 1
  fi
  key="$(sed -n 's/^ROADIE_PI_KEY=//p' "$env_file" | tail -n 1)"
  agent_dir="$(sed -n 's/^PI_CODING_AGENT_DIR=//p' "$env_file" | tail -n 1)"
  if [ -z "$key" ]; then
    echo "local Cook provider route unauthenticated: $env_file has no ROADIE_PI_KEY"
    return 1
  fi
  if [ -z "$agent_dir" ] || [ ! -f "$agent_dir/models.json" ]; then
    echo "local Cook provider route unauthenticated: PI_CODING_AGENT_DIR '${agent_dir}' has no models.json"
    return 1
  fi
  echo "local Cook provider route authenticated ($env_file, $agent_dir)"
}
