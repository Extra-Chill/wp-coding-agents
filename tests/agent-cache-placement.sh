#!/bin/bash
# Hermetic phase-1 cache placement and read-only doctor coverage.
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/bridge-service-adapters.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
LOCAL_MODE=false PLATFORM=linux
DM_WORKSPACE_DIR=""
[ -z "$(agent_cache_paths)" ] || fail 'unset workspace changed defaults'
DM_WORKSPACE_DIR="$TMP/work space"
PLATFORM=mac
[ -z "$(agent_cache_paths)" ] || fail 'mac changed defaults'
PLATFORM=linux LOCAL_MODE=true
[ -z "$(agent_cache_paths)" ] || fail 'local install changed defaults'
LOCAL_MODE=false
SERVICE_USER="$(id -un)"
DRY_RUN=true
bridge_service_adapter_apply_agent_cache
[ ! -e "$DM_WORKSPACE_DIR" ] || fail 'dry run mutated disk'
DRY_RUN=false
# Stub only the privileged syscall: validate its arguments and create as self.
install() {
  [ "$1 $2 $3 $4 $5 $6 $7" = "-d -m 0700 -o $SERVICE_USER -g $(id -gn)" ] || fail 'ownership/mode arguments'
  mkdir -p -- "$8"
  chmod 0700 "$8"
}
bridge_service_adapter_apply_agent_cache
bridge_service_adapter_apply_agent_cache
bridge_service_adapter_verify_agent_cache
count=0
while IFS= read -r assignment; do
  path="${assignment#*=}"
  [ -d "$path" ] || fail "missing $path"
  [ "$(stat -c %a "$path")" = 700 ] || fail "non-private $path"
  grep -Fqx "Environment=$(systemd_quote "$assignment")" <<< "$(agent_tmpdir_systemd_env)" || fail "missing rendered $assignment"
  grep -Fqx "Environment=$(systemd_quote "$assignment")" <<< "$(homeboy_data_dir_systemd_env)" || fail "missing daemon $assignment"
  count=$((count + 1))
done < <(agent_cache_paths)
[ "$count" = 7 ] || fail 'missing cache knobs'
! agent_cache_paths | grep -q XDG_DATA_HOME || fail 'live data redirected'
# Adapter precedes consumers, including bridge-only runs.
[ "$(bridge_service_adapter_names | head -1)" = agent-cache ] || fail 'cache directories not first'
mkdir -p "$TMP/home/.roadie" "$TMP/site"
printf 'existing state' > "$TMP/home/.roadie/sessions.db"
AGENT_STATE_WARNING_KB=10
agent_state_size_kb() { printf '11\n'; }
agent_state_filesystem() { printf '1\n'; }
grep -q 'site-data filesystem' <<< "$(agent_state_doctor "$TMP/home" "$TMP/site")" || fail 'missing doctor warning'
[ "$(< "$TMP/home/.roadie/sessions.db")" = 'existing state' ] || fail 'doctor changed state'
agent_state_size_kb() { printf '9\n'; }
[ -z "$(agent_state_doctor "$TMP/home" "$TMP/site")" ] || fail 'warned below threshold'
agent_state_size_kb() { printf '11\n'; }
agent_state_filesystem() { case "$1" in */site) echo 1 ;; *) echo 2 ;; esac; }
[ -z "$(agent_state_doctor "$TMP/home" "$TMP/site")" ] || fail 'warned across filesystems'
agent_state_filesystem() { echo 1; }
mv "$TMP/home/.roadie" "$TMP/redirected-state"
ln -s "$TMP/redirected-state" "$TMP/home/.roadie"
[ -z "$(agent_state_doctor "$TMP/home" "$TMP/site")" ] || fail 'counted redirected state'
rm "$TMP/home/.roadie"
mv "$TMP/redirected-state" "$TMP/home/.roadie"
DM_WORKSPACE_DIR=""
[ -z "$(agent_state_doctor "$TMP/home" "$TMP/site")" ] || fail 'warning without workspace'
DM_WORKSPACE_DIR="$TMP/work space" PLATFORM=mac
[ -z "$(agent_state_doctor "$TMP/home" "$TMP/site")" ] || fail 'warning on mac'
echo 'OK: agent cache placement and disk doctor'
