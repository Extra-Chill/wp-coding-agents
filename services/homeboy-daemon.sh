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
  local bin
  bin="$(homeboy_service_bin)"
  cat <<EOF
[Unit]
Description=Homeboy daemon (wp-coding-agents)
After=network-online.target
Wants=network-online.target
# Keep retrying while another launcher still owns the daemon lock.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SERVICE_HOME
Environment=HOME=$SERVICE_HOME
${HOMEBOY_DATA_DIR:+Environment=HOMEBOY_DATA_DIR=$HOMEBOY_DATA_DIR}
Environment=PATH=$(dirname "$bin"):/usr/local/bin:/usr/bin:/bin
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
  local unit unit_path
  unit="$(homeboy_daemon_unit_name)"
  unit_path="$(homeboy_daemon_unit_path)"

  if [ ! -f "$unit_path" ]; then
    write_file "$unit_path" "$(homeboy_daemon_render_systemd_service)"
    [ "${DRY_RUN:-false}" = true ] && return 0
    systemctl daemon-reload
    homeboy_daemon_adopt_unsupervised
    systemctl enable --now "$unit"
    log "Homeboy daemon: supervised by $unit"
    return 0
  fi

  _smart_update_systemd_unit "$unit_path" "$(homeboy_daemon_render_systemd_service)" "$unit"
  [ "${DRY_RUN:-false}" = true ] && return 0
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$unit"; then
    homeboy_daemon_adopt_unsupervised
    systemctl start "$unit"
    return 0
  fi
  homeboy_daemon_converge_binary
}

homeboy_daemon_service_verify() {
  homeboy_daemon_service_applicable || return 0
  [ -f "$(homeboy_daemon_unit_path)" ]
}
