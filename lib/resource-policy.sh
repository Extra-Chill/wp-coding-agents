#!/bin/bash
# Generic host resource policy. systemd percentages are relative to MemTotal.
# Keep these finite: infinity/zero would defeat the production-host boundary.
agent_systemd_resource_policy() {
  printf 'Slice=wp-coding-agents.slice\n'
}

agent_systemd_slice_policy() {
  local high="${AGENT_MEMORY_HIGH_PERCENT:-40}" max="${AGENT_MEMORY_MAX_PERCENT:-45}"
  if ! [[ "$high" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] ||
     [ "${#high}" -gt 2 ] || [ "${#max}" -gt 2 ] ||
     [ "$((10#$high))" -lt 1 ] || [ "$((10#$max))" -lt "$((10#$high))" ] || [ "$((10#$max))" -gt 99 ]; then
    echo 'Invalid agent memory percentages: require 1 <= high <= max <= 99' >&2
    return 1
  fi
  printf 'MemoryHigh=%s%%\nMemoryMax=%s%%\n' "$high" "$max"
}

host_resource_policy_services() {
  [ "${PLATFORM:-linux}" != mac ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
    awk '$1 ~ /^(mariadb|mysql|mysqld|redis-server|redis|valkey|valkey-server|php-fpm|php[0-9.]+-fpm)\.service$/ {print $1}'
}

host_has_local_database() {
  host_resource_policy_services | grep -Eq '^(mariadb|mysql|mysqld)\.service$'
}

host_resource_policy_reconcile() {
  [ "${PLATFORM:-linux}" != mac ] && [ "${LOCAL_MODE:-false}" != true ] || return 0
  local unit score file content changed=false policy
  policy="$(agent_systemd_slice_policy)" || return $?
  file="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/wp-coding-agents.slice"
  content="$(printf '[Unit]\nDescription=Combined managed agent memory budget\n[Slice]\n%s\n' "$policy")"
  if [ ! -f "$file" ] || [ "$(<"$file")" != "$content" ]; then
    run_cmd mkdir -p "$(dirname "$file")" || return $?
    write_file "$file" "$content" || return $?
    changed=true
  fi
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    case "$unit" in
      mariadb.service|mysql.service|mysqld.service) score=-600 ;;
      redis*.service|valkey*.service) score=-500 ;;
      *) score=-300 ;;
    esac
    file="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$unit.d/wp-coding-agents-oom.conf"
    content="$(printf '[Service]\nOOMScoreAdjust=%s\n' "$score")"
    if [ -f "$file" ] && [ "$(<"$file")" = "$content" ]; then continue; fi
    run_cmd mkdir -p "$(dirname "$file")" || return $?
    write_file "$file" "$content" || return $?
    changed=true
  done < <(host_resource_policy_services)
  if [ "$changed" = true ]; then run_cmd systemctl daemon-reload; fi
}

# Conservative co-tenant allowances, once per service class (aliases are not
# additional processes). Operators should size these to DB buffers, twice Redis
# maxmemory for fork, and the FPM pool. Never reserve less than live usage.
host_resource_policy_reserved_bytes() {
  local ram="$1" unit class current reserve total=0 seen=' '
  while IFS= read -r unit; do
    case "$unit" in
      mariadb.service|mysql.service|mysqld.service) class=db; reserve="${HOST_DB_RESERVED_MB:-$((ram * 25 / 100 / 1048576))}" ;;
      redis*.service|valkey*.service) class=cache; reserve="${HOST_CACHE_RESERVED_MB:-$((ram * 10 / 100 / 1048576))}" ;;
      *) class="$unit"; reserve="${HOST_FPM_RESERVED_MB:-$((ram * 20 / 100 / 1048576))}" ;;
    esac
    [[ "$seen" != *" $class "* ]] || continue
    seen+="$class "
    if ! [[ "$reserve" =~ ^[0-9]+$ ]]; then
      echo 'Invalid host service memory reservation (expected MiB)' >&2
      return 1
    fi
    reserve=$((10#$reserve * 1048576))
    current="$(systemctl show "$unit" --property=MemoryCurrent --value 2>/dev/null)" || current=0
    if [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" != 18446744073709551615 ] && [ "$current" -gt "$reserve" ]; then
      reserve="$current"
    fi
    total=$((total + reserve))
  done < <(host_resource_policy_services)
  echo "$total"
}

# warn() belongs to the verifier; keeping probes here makes them testable with
# synthetic procfs and systemctl, without touching running data services.
host_resource_policy_verify() {
  [ "${PLATFORM:-linux}" != mac ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit pid configured live ram reserved ceiling
  while IFS= read -r unit; do
    pid="$(systemctl show "$unit" --property=MainPID --value 2>/dev/null)" || continue
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    configured="$(systemctl show "$unit" --property=OOMScoreAdjust --value 2>/dev/null)" || continue
    [ -r "${PROC_ROOT:-/proc}/$pid/oom_score_adj" ] || continue
    live="$(<"${PROC_ROOT:-/proc}/$pid/oom_score_adj")"
    if [ -n "$configured" ] && [ "$live" != "$configured" ]; then
      warn "$unit live oom_score_adj=$live differs from unit OOMScoreAdjust=$configured; restart pending"
    fi
  done < <(host_resource_policy_services)
  ram="$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' "${PROC_ROOT:-/proc}/meminfo" 2>/dev/null)"
  [[ "$ram" =~ ^[1-9][0-9]*$ ]] || return 0
  reserved="$(host_resource_policy_reserved_bytes "$ram")" || { warn 'Invalid host memory reservations'; return 0; }
  ceiling="$(systemctl show wp-coding-agents.slice --property=MemoryMax --value 2>/dev/null)" || ceiling=infinity
  case "$ceiling" in
    ''|infinity|0|18446744073709551615) warn 'Combined agent slice has no effective memory ceiling; run upgrade.sh' ;;
    *)
      if [[ "$ceiling" =~ ^[0-9]+$ ]] && [ "$ceiling" -gt "$((ram - reserved))" ]; then
        warn "Combined agent ceiling ($ceiling bytes) exceeds RAM minus reserved service memory ($((ram - reserved)) bytes)"
      fi ;;
  esac
}

# Read the effective property, including operator drop-ins, not just our file.
agent_systemd_memory_ceiling_present() {
  local ceiling
  ceiling="$(systemctl show "$1" --property=MemoryMax --value 2>/dev/null)" || return 1
  case "$ceiling" in ''|infinity|0|18446744073709551615) return 1 ;; esac
  return 0
}
