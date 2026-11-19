#!/bin/bash
# Resource policy tests: no host writes or real systemctl calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SYSTEMD_UNIT_DIR="$tmp/units" PLATFORM=linux LOCAL_MODE=false DRY_RUN=false
calls="$tmp/calls"
systemctl() {
  echo "$*" >> "$calls"
  case "$1" in
    list-unit-files) printf '%s\n' "${services:-}" ;;
    show) printf '%s\n' "${ceiling:-infinity}" ;;
    daemon-reload) ;;
    *) return 1 ;;
  esac
}
assert_contains() { grep -Fq -- "$2" "$1" || { echo "Missing $2 in $1"; exit 1; }; }
agent_systemd_resource_policy > "$tmp/default"
assert_contains "$tmp/default" 'MemoryHigh=60%'
assert_contains "$tmp/default" 'MemoryMax=75%'
AGENT_MEMORY_HIGH_PERCENT=40 AGENT_MEMORY_MAX_PERCENT=55 agent_systemd_resource_policy > "$tmp/override"
assert_contains "$tmp/override" 'MemoryHigh=40%'
assert_contains "$tmp/override" 'MemoryMax=55%'
if AGENT_MEMORY_MAX_PERCENT=infinity agent_systemd_resource_policy 2>/dev/null; then exit 1; fi
if AGENT_MEMORY_HIGH_PERCENT=80 agent_systemd_resource_policy 2>/dev/null; then exit 1; fi
# Real service renderers consume the shared helper.
source "$ROOT/services/homeboy-daemon.sh"
source "$ROOT/services/datamachine-worker.sh"
# Existing dependencies are irrelevant to the resource lines.
SERVICE_USER=agent SERVICE_HOME=/home/agent SITE_PATH=/srv/wp
homeboy_data_dir_systemd_env() { :; }
homeboy_service_bin() { echo /usr/local/bin/homeboy; }
_service_path_value() { echo /usr/local/bin:/usr/bin:/bin; }
_resolve_node_bin_dir() { :; }
_datamachine_worker_command() { echo 'wp datamachine worker run --once'; }
homeboy_daemon_render_systemd_service > "$tmp/daemon"
datamachine_worker_render_systemd_service > "$tmp/worker"
for rendered in daemon worker; do
  assert_contains "$tmp/$rendered" 'MemoryHigh=60%'
  assert_contains "$tmp/$rendered" 'MemoryMax=75%'
done
# Check all templates retain the shared rendering call.
for template in bridges/roadie.sh services/homeboy-daemon.sh services/datamachine-worker.sh; do
  assert_contains "$ROOT/$template" 'resource_policy="$(agent_systemd_resource_policy)"'
  assert_contains "$ROOT/$template" '$resource_policy'
done
services=$'mariadb.service enabled\nmysql.service alias\nphp8.4-fpm.service enabled\nssh.service enabled'
host_has_local_database
host_resource_policy_reconcile
assert_contains "$SYSTEMD_UNIT_DIR/mariadb.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-600'
assert_contains "$SYSTEMD_UNIT_DIR/mysql.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-600'
assert_contains "$SYSTEMD_UNIT_DIR/php8.4-fpm.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-300'
[ ! -e "$SYSTEMD_UNIT_DIR/ssh.service.d" ]
[ "$(grep -c '^daemon-reload$' "$calls")" -eq 1 ]
host_resource_policy_reconcile
[ "$(grep -c '^daemon-reload$' "$calls")" -eq 1 ]
# Repair drift, preserving unrelated operator drop-ins.
echo '# operator' > "$SYSTEMD_UNIT_DIR/mariadb.service.d/operator.conf"
echo 'stale' > "$SYSTEMD_UNIT_DIR/mariadb.service.d/wp-coding-agents-oom.conf"
host_resource_policy_reconcile
assert_contains "$SYSTEMD_UNIT_DIR/mariadb.service.d/operator.conf" '# operator'
assert_contains "$SYSTEMD_UNIT_DIR/mariadb.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-600'
SYSTEMD_UNIT_DIR="$tmp/skipped"
DRY_RUN=true host_resource_policy_reconcile >/dev/null
[ ! -e "$SYSTEMD_UNIT_DIR" ]
PLATFORM=mac host_resource_policy_reconcile
LOCAL_MODE=true host_resource_policy_reconcile
services='' host_resource_policy_reconcile
[ ! -e "$SYSTEMD_UNIT_DIR" ]
if services='' host_has_local_database; then exit 1; fi
for ceiling in infinity 0 18446744073709551615 ''; do
  if agent_systemd_memory_ceiling_present agent.service; then exit 1; fi
done
ceiling=1073741824 agent_systemd_memory_ceiling_present agent.service
echo 'PASS: resource policy'
