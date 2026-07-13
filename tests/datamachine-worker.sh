#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export SITE_PATH=/var/www/site SERVICE_USER=chubes SERVICE_HOME=/home/chubes
export WP_CMD=wp LOCAL_MODE=false PLATFORM=linux DRY_RUN=false
source "$SCRIPT_DIR/services/datamachine-worker.sh"

service="$(datamachine_worker_render_systemd_service)"
timer="$(datamachine_worker_render_systemd_timer)"
plist="$(datamachine_worker_render_launchd com.wp.datamachine-worker)"

snapshot_dir="$SCRIPT_DIR/tests/__snapshots__/datamachine-worker"
diff -u "$snapshot_dir/systemd-service" <(printf '%s\n' "$service")
diff -u "$snapshot_dir/systemd-timer" <(printf '%s\n' "$timer")
diff -u "$snapshot_dir/launchd" <(printf '%s\n' "$plist")

grep -q '^User=chubes$' <<< "$service"
grep -q 'wp cron event run --due-now' <<< "$service"
grep -q 'wp datamachine worker run --once' <<< "$service"
grep -q '^OnUnitActiveSec=2min$' <<< "$timer"
grep -q '<integer>120</integer>' <<< "$plist"
grep -q 'com.wp.datamachine-worker' <<< "$plist"

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
grep -Fq "'$studio_bin' wp cron event run --due-now && '$studio_bin' wp datamachine worker run --once" <<< "$studio_plist"
echo "PASS: tests/datamachine-worker.sh"
