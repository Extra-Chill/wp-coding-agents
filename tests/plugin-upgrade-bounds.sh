#!/bin/bash
# Deterministic slow/hung coverage for bounded plugin upgrade children.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/plugin-upgrade.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCRIPT_DIR="$ROOT_DIR"
SITE_PATH="$TMP/site"
DRY_RUN=false
PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS=4
PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS=20
PLUGIN_UPDATE_PROGRESS_SECONDS=1
PLUGIN_UPDATE_KILL_GRACE_SECONDS=1
PLUGIN_UPDATE_STARTED_AT="$(date +%s)"
PLUGIN_UPDATE_FAILURES=()
PLUGIN_UPDATE_POINTER_EVIDENCE=()
PENDING_ITEMS=()
LOG=""

log() { LOG="$LOG$*\n"; }
warn() { LOG="$LOG$*\n"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

slow="$ROOT_DIR/tests/fixtures/plugin-updates/slow.sh"
hung="$ROOT_DIR/tests/fixtures/plugin-updates/hung.sh"
partial="$ROOT_DIR/tests/fixtures/plugin-updates/partial-pointer-hung.sh"

# WordPress Studio may emit a PHP preamble on stdout before valid WP-CLI JSON.
plugin_update_state_from_json $'\nDeprecated: fixture warning\n[{"name":"data-machine-code","status":"active","version":"1.2.3"}]' data-machine-code || fail "preamble-bearing plugin JSON was refused"
[ "$PLUGIN_STATE_TUPLE" = $'1.2.3\tactive' ] || fail "preamble-bearing plugin JSON returned the wrong state"
if plugin_update_state_from_json $'Deprecated: no JSON follows' data-machine-code; then
  fail "malformed plugin output was accepted"
fi

# A slow child emits progress and still completes under its deadline.
PLUGIN_FIXTURE_SLEEP_SECONDS=2 plugin_update_run_phase fixture slow-sync "$slow" || fail "slow fixture timed out"
[ "$PLUGIN_PHASE_OUTPUT" = slow-fixture-complete ] || fail "slow fixture output was not retained"
case "$LOG" in *"phase=slow-sync progress"*"phase=slow-sync terminal=complete"*) : ;; *) fail "slow fixture omitted progress or terminal evidence" ;; esac

# A hung child is named, killed as its own process group, and returns 124.
LOG=""
PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS=1
PLUGIN_FIXTURE_PID_FILE="$TMP/hung.pid"; export PLUGIN_FIXTURE_PID_FILE
started="$(date +%s)"
if plugin_update_run_phase fixture hung-sync "$hung"; then
  fail "hung fixture completed"
else
  status=$?
fi
elapsed=$(($(date +%s) - started))
[ "$status" -eq 124 ] || fail "hung fixture returned $status instead of 124"
[ "$elapsed" -le 4 ] || fail "hung fixture exceeded practical cleanup bound (${elapsed}s)"
case "$LOG" in *"phase=hung-sync terminal=timeout"*"timed-out-child:"*"resume:"*) : ;; *) fail "hung fixture omitted timeout child or resume evidence" ;; esac
child_pid="$(cat "$TMP/hung.pid")"
if kill -0 "$child_pid" 2>/dev/null; then fail "timed-out fixture child $child_pid survived"; fi

# A timeout after an atomic DMC pointer switch reports partial mutation and
# verifies that WordPress still sees the same active installed version.
PLUGIN="$SITE_PATH/wp-content/plugins/data-machine-code"
mkdir -p "$PLUGIN/.wp-coding-agents-releases/old" "$PLUGIN/.wp-coding-agents-releases/new"
printf '<?php\n/* Version: 1.0.0 */\n' > "$PLUGIN/data-machine-code.php"
printf '<?php\n/* Version: 1.0.0 */\n' > "$PLUGIN/.wp-coding-agents-releases/old/data-machine-code.php"
printf '<?php\n/* Version: 1.0.0 */\n' > "$PLUGIN/.wp-coding-agents-releases/new/data-machine-code.php"
ln -s .wp-coding-agents-releases/old "$PLUGIN/.wp-coding-agents-release-current"
wp_cmd() { printf '[{"name":"data-machine-code","status":"active","version":"1.0.0"}]\n'; }
partial_update() { plugin_update_run_phase data-machine-code release-pointer-switch "$partial" "$PLUGIN"; }

LOG=""
PLUGIN_UPDATE_STARTED_AT="$(date +%s)"
PLUGIN_UPDATE_FAILURES=()
PLUGIN_UPDATE_POINTER_EVIDENCE=()
PENDING_ITEMS=()
if plugin_update_execute data-machine-code partial_update; then
  fail "partial pointer fixture completed"
else
  status=$?
fi
[ "$status" -eq "$PLUGIN_UPDATE_EXIT_PARTIAL" ] || fail "partial apply did not return typed partial status"
plugin_update_verify_installed_plugins data-machine-code || true
[ "$status" -eq "$PLUGIN_UPDATE_EXIT_PARTIAL" ] || fail "partial fixture did not return typed partial status"
[ "$(readlink "$PLUGIN/.wp-coding-agents-release-current")" = .wp-coding-agents-releases/new ] || fail "fixture did not switch release pointer"
case "${PLUGIN_UPDATE_POINTER_EVIDENCE[*]}" in *"changed=yes"*"before=.wp-coding-agents-releases/old"*"after=.wp-coding-agents-releases/new"*) : ;; *) fail "partial release-pointer mutation was not reported" ;; esac
case "$LOG" in *"installed-after version=1.0.0 active=yes"*"terminal=partial-failure"*) : ;; *) fail "partial terminal verification evidence missing" ;; esac

echo "plugin-upgrade-bounds tests passed"
