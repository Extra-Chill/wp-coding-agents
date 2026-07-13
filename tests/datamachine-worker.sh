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
grep -q 'wp datamachine worker run --once' <<< "$service"
grep -q '^OnUnitActiveSec=2min$' <<< "$timer"
grep -q '<integer>120</integer>' <<< "$plist"
grep -q 'com.wp.datamachine-worker' <<< "$plist"
echo "PASS: tests/datamachine-worker.sh"
