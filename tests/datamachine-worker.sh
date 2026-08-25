#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export SITE_PATH=/var/www/site SERVICE_USER=chubes SERVICE_HOME=/home/chubes
export WP_CMD=wp LOCAL_MODE=false PLATFORM=linux DRY_RUN=false
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/services/datamachine-worker.sh"

service="$(datamachine_worker_render_systemd_service)"
timer="$(datamachine_worker_render_systemd_timer)"
plist="$(datamachine_worker_render_launchd com.wp.datamachine-worker)"

snapshot_dir="$SCRIPT_DIR/tests/__snapshots__/datamachine-worker"
diff -u "$snapshot_dir/systemd-service" <(printf '%s\n' "$service")
diff -u "$snapshot_dir/systemd-timer" <(printf '%s\n' "$timer")
diff -u "$snapshot_dir/launchd" <(printf '%s\n' "$plist")

grep -q '^User=chubes$' <<< "$service"
grep -q 'wp datamachine worker run --once' <<< "$service"
if grep -q 'wp cron event run --due-now' <<< "$service"; then
  echo "systemd worker must not execute generic WP-Cron" >&2
  exit 1
fi
grep -q '^OnUnitActiveSec=2min$' <<< "$timer"
grep -q '<integer>120</integer>' <<< "$plist"
grep -q 'com.wp.datamachine-worker' <<< "$plist"

if command -v plutil >/dev/null 2>&1; then
  saved_site_path="$SITE_PATH"
  saved_service_home="$SERVICE_HOME"
  SITE_PATH='/tmp/site & <queue>'
  SERVICE_HOME='/tmp/home & <worker>'
  metachar_plist="$(datamachine_worker_render_launchd com.wp.datamachine-worker)"
  metachar_file="$(mktemp)"
  printf '%s\n' "$metachar_plist" > "$metachar_file"
  plutil -lint "$metachar_file" >/dev/null
  [ "$(plutil -extract WorkingDirectory raw -o - "$metachar_file")" = "$SITE_PATH" ]
  [ "$(plutil -extract EnvironmentVariables.HOME raw -o - "$metachar_file")" = "$SERVICE_HOME" ]
  [ "$(plutil -extract ProgramArguments.2 raw -o - "$metachar_file")" = "$(_datamachine_worker_command)" ]
  rm -f "$metachar_file"
  SITE_PATH="$saved_site_path"
  SERVICE_HOME="$saved_service_home"
fi

# launchd has a minimal PATH. Resolve a Studio CLI from a directory outside
# that PATH and assert the command embeds its absolute, shell-quoted path.
studio_root="/tmp/datamachine-worker-studio-path"
studio_bin="$studio_root/studio tools/studio"
[ ! -e "$studio_root" ] || {
  echo "FAIL: test directory already exists: $studio_root" >&2
  exit 1
}
mkdir -p "$(dirname "$studio_bin")"
printf '#!/bin/sh\n' > "$studio_bin"
chmod +x "$studio_bin"
trap 'rm -r "$studio_root"' EXIT

saved_path="$PATH"
PATH="$(dirname "$studio_bin"):$saved_path"
WP_CMD="studio wp"
STUDIO_BIN="$studio_root/missing-studio"
if datamachine_worker_prepare_command; then
  echo "FAIL: missing Studio executable was accepted" >&2
  exit 1
fi
unset STUDIO_BIN
datamachine_worker_prepare_command
studio_plist="$(datamachine_worker_render_launchd com.wp.datamachine-worker)"
PATH="$saved_path"

diff -u "$snapshot_dir/launchd-studio-absolute-path" <(printf '%s\n' "$studio_plist")
grep -Fq "'$studio_bin' wp datamachine worker run --once" <<< "$studio_plist"
if grep -q 'wp cron event run --due-now' <<< "$studio_plist"; then
  echo "launchd worker must not execute generic WP-Cron" >&2
  exit 1
fi

if command -v plutil >/dev/null 2>&1; then
  plist_file="$studio_root/datamachine-worker.plist"
  printf '%s\n' "$studio_plist" > "$plist_file"
  plutil -lint "$plist_file" >/dev/null
  rendered_command="$(plutil -extract ProgramArguments.2 raw -o - "$plist_file")"
  [ "$rendered_command" = "$(_datamachine_worker_command)" ] || {
    echo "FAIL: escaped LaunchAgent command did not round-trip" >&2
    exit 1
  }
fi

# Legacy installs have no opt-in marker. Reconciliation must remove their
# managed service, while explicit enablement persists across later upgrades.
state_root="$studio_root/state"
SERVICE_HOME="$state_root/home"
SITE_PATH="$state_root/site"
DATAMACHINE_WORKER_LAUNCHD_DIR="$state_root/LaunchAgents"
DATAMACHINE_WORKER_SYSTEMD_DIR="$state_root/systemd"
calls="$state_root/service-calls"
mkdir -p "$SERVICE_HOME" "$SITE_PATH" "$DATAMACHINE_WORKER_LAUNCHD_DIR" "$DATAMACHINE_WORKER_SYSTEMD_DIR"
launchctl() { printf 'launchctl %s\n' "$*" >> "$calls"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }

WP_CMD=wp
LOCAL_MODE=true
PLATFORM=mac
unset DATAMACHINE_WORKER_REQUEST WP_CODING_AGENTS_DATAMACHINE_WORKER_ENABLED
legacy_plist="$DATAMACHINE_WORKER_LAUNCHD_DIR/com.wp.datamachine-worker.plist"
printf 'legacy\n' > "$legacy_plist"
datamachine_worker_reconcile >/dev/null
[ ! -e "$legacy_plist" ]
[ ! -e "$(datamachine_worker_state_file)" ]
grep -q 'launchctl bootout' "$calls"

WP_CODING_AGENTS_DATAMACHINE_WORKER_ENABLED=true
[ "$(datamachine_worker_desired_state)" = enabled ]
WP_CODING_AGENTS_DATAMACHINE_WORKER_ENABLED=false
[ "$(datamachine_worker_desired_state)" = disabled ]
unset WP_CODING_AGENTS_DATAMACHINE_WORKER_ENABLED

DATAMACHINE_WORKER_REQUEST=enabled
datamachine_worker_reconcile >/dev/null
[ -f "$legacy_plist" ]
[ "$(cat "$(datamachine_worker_state_file)")" = enabled ]
grep -q 'launchctl bootstrap' "$calls"

unset DATAMACHINE_WORKER_REQUEST
datamachine_worker_reconcile >/dev/null
[ -f "$legacy_plist" ]

DATAMACHINE_WORKER_REQUEST=disabled
datamachine_worker_reconcile >/dev/null
[ ! -e "$legacy_plist" ]
[ ! -e "$(datamachine_worker_state_file)" ]

LOCAL_MODE=false
printf 'service\n' > "$DATAMACHINE_WORKER_SYSTEMD_DIR/datamachine-worker.service"
printf 'timer\n' > "$DATAMACHINE_WORKER_SYSTEMD_DIR/datamachine-worker.timer"
datamachine_worker_reconcile >/dev/null
[ ! -e "$DATAMACHINE_WORKER_SYSTEMD_DIR/datamachine-worker.service" ]
[ ! -e "$DATAMACHINE_WORKER_SYSTEMD_DIR/datamachine-worker.timer" ]
grep -q 'systemctl disable --now datamachine-worker.timer' "$calls"
grep -q 'systemctl daemon-reload' "$calls"

echo "PASS: tests/datamachine-worker.sh"
