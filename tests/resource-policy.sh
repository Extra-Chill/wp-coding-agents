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
agent_systemd_slice_policy > "$tmp/default"
assert_contains "$tmp/default" 'MemoryHigh=40%'
assert_contains "$tmp/default" 'MemoryMax=45%'
AGENT_MEMORY_HIGH_PERCENT=40 AGENT_MEMORY_MAX_PERCENT=55 agent_systemd_slice_policy > "$tmp/override"
assert_contains "$tmp/override" 'MemoryHigh=40%'
assert_contains "$tmp/override" 'MemoryMax=55%'
if AGENT_MEMORY_MAX_PERCENT=infinity agent_systemd_slice_policy 2>/dev/null; then exit 1; fi
if AGENT_MEMORY_HIGH_PERCENT=80 agent_systemd_slice_policy 2>/dev/null; then exit 1; fi
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
  assert_contains "$tmp/$rendered" 'Slice=wp-coding-agents.slice'
  if grep -q '^MemoryMax=' "$tmp/$rendered"; then exit 1; fi
done
# Check all templates retain the shared rendering call.
for template in bridges/roadie.sh services/homeboy-daemon.sh services/datamachine-worker.sh; do
  assert_contains "$ROOT/$template" 'resource_policy="$(agent_systemd_resource_policy)"'
  assert_contains "$ROOT/$template" '$resource_policy'
done
services=$'mariadb.service enabled\nmysql.service alias\nphp8.4-fpm.service enabled\nredis-server.service enabled\nredis.service alias\nvalkey.service enabled\nvalkey-server.service enabled\nssh.service enabled'
host_has_local_database
host_resource_policy_reconcile
assert_contains "$SYSTEMD_UNIT_DIR/mariadb.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-600'
assert_contains "$SYSTEMD_UNIT_DIR/mysql.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-600'
assert_contains "$SYSTEMD_UNIT_DIR/php8.4-fpm.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-300'
for cache in redis-server redis valkey valkey-server; do
  assert_contains "$SYSTEMD_UNIT_DIR/$cache.service.d/wp-coding-agents-oom.conf" 'OOMScoreAdjust=-500'
done
assert_contains "$SYSTEMD_UNIT_DIR/wp-coding-agents.slice" '[Slice]'
assert_contains "$SYSTEMD_UNIT_DIR/wp-coding-agents.slice" 'MemoryMax=45%'
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
AGENT_MEMORY_HIGH_PERCENT=35 AGENT_MEMORY_MAX_PERCENT=50 host_resource_policy_reconcile
assert_contains "$SYSTEMD_UNIT_DIR/wp-coding-agents.slice" 'MemoryHigh=35%'
assert_contains "$SYSTEMD_UNIT_DIR/wp-coding-agents.slice" 'MemoryMax=50%'
# Invalid overrides must not write a partial slice.
if AGENT_MEMORY_MAX_PERCENT=100 host_resource_policy_reconcile 2>/dev/null; then exit 1; fi
assert_contains "$SYSTEMD_UNIT_DIR/wp-coding-agents.slice" 'MemoryMax=50%'
SYSTEMD_UNIT_DIR="$tmp/skipped"
DRY_RUN=true host_resource_policy_reconcile >/dev/null
[ ! -e "$SYSTEMD_UNIT_DIR" ]
PLATFORM=mac host_resource_policy_reconcile
LOCAL_MODE=true host_resource_policy_reconcile
# A host without data services still gets the combined slice.
services='' host_resource_policy_reconcile
[ -e "$SYSTEMD_UNIT_DIR/wp-coding-agents.slice" ]
if services='' host_has_local_database; then exit 1; fi
for ceiling in infinity 0 18446744073709551615 ''; do
  if agent_systemd_memory_ceiling_present agent.service; then exit 1; fi
done
ceiling=1073741824 agent_systemd_memory_ceiling_present agent.service
# Verifier probes: byte-valued systemd properties and a synthetic procfs.
export PROC_ROOT="$tmp/proc"
mkdir -p "$PROC_ROOT/123"
printf 'MemTotal: 10485760 kB\n' > "$PROC_ROOT/meminfo"
echo 0 > "$PROC_ROOT/123/oom_score_adj"
services=$'mysql.service alias\nmariadb.service enabled\nredis.service enabled\nphp-fpm.service enabled'
systemctl() {
  case "$1:$*" in
    list-unit-files:*) printf '%s\n' "$services" ;;
    *--property=MainPID*) echo 123 ;;
    *--property=OOMScoreAdjust*) echo -500 ;;
    *--property=MemoryCurrent*) echo "${current:-0}" ;;
    *--property=MemoryMax*) echo "${ceiling:-4831838208}" ;;
    *) return 1 ;;
  esac
}
warn() { echo "$*"; }
# DB aliases and cache aliases must not multiply allowances.
[ "$(host_resource_policy_reserved_bytes 10737418240)" -eq 5905580032 ]
HOST_DB_RESERVED_MB=4096 HOST_CACHE_RESERVED_MB=2048 HOST_FPM_RESERVED_MB=3072 \
  host_resource_policy_verify > "$tmp/warnings"
assert_contains "$tmp/warnings" 'restart pending'
assert_contains "$tmp/warnings" 'exceeds RAM minus reserved service memory'
echo -500 > "$PROC_ROOT/123/oom_score_adj"
host_resource_policy_verify > "$tmp/healthy"
[ ! -s "$tmp/healthy" ]
# Live cgroup usage above the configured allowance also reduces headroom.
current=4294967296 host_resource_policy_verify > "$tmp/live-usage"
assert_contains "$tmp/live-usage" 'exceeds RAM minus reserved service memory'
ceiling=infinity host_resource_policy_verify > "$tmp/unbounded"
assert_contains "$tmp/unbounded" 'no effective memory ceiling'
echo 'PASS: resource policy'
