#!/bin/bash
# Generic host resource policy. systemd percentages are relative to MemTotal.
# Keep these finite: infinity/zero would defeat the production-host boundary.
agent_systemd_resource_policy() {
  local high="${AGENT_MEMORY_HIGH_PERCENT:-60}" max="${AGENT_MEMORY_MAX_PERCENT:-75}"
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
    awk '$1 ~ /^(mariadb|mysql|mysqld|php-fpm|php[0-9.]+-fpm)\.service$/ {print $1}'
}

host_has_local_database() {
  host_resource_policy_services | grep -Eq '^(mariadb|mysql|mysqld)\.service$'
}

host_resource_policy_reconcile() {
  [ "${PLATFORM:-linux}" != mac ] && [ "${LOCAL_MODE:-false}" != true ] || return 0
  local unit score file content changed=false
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    case "$unit" in mariadb.service|mysql.service|mysqld.service) score=-600 ;; *) score=-300 ;; esac
    file="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$unit.d/wp-coding-agents-oom.conf"
    content="$(printf '[Service]\nOOMScoreAdjust=%s\n' "$score")"
    if [ -f "$file" ] && [ "$(<"$file")" = "$content" ]; then continue; fi
    run_cmd mkdir -p "$(dirname "$file")" || return $?
    write_file "$file" "$content" || return $?
    changed=true
  done < <(host_resource_policy_services)
  if [ "$changed" = true ]; then run_cmd systemctl daemon-reload; fi
}

# Read the effective property, including operator drop-ins, not just our file.
agent_systemd_memory_ceiling_present() {
  local ceiling
  ceiling="$(systemctl show "$1" --property=MemoryMax --value 2>/dev/null)" || return 1
  case "$ceiling" in ''|infinity|0|18446744073709551615) return 1 ;; esac
  return 0
}
