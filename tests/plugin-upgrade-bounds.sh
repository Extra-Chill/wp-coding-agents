#!/bin/bash
# Deterministic slow/hung coverage for bounded plugin upgrade children.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/plugin-upgrade.sh"
source "$ROOT_DIR/lib/desired-state-reconciler.sh"

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
PENDING_ITEMS=()
LOG=""

log() { LOG="$LOG$*"$'\n'; }
warn() { LOG="$LOG$*"$'\n'; }
fail() { echo "FAIL: $1" >&2; exit 1; }

slow="$ROOT_DIR/tests/fixtures/plugin-updates/slow.sh"
hung="$ROOT_DIR/tests/fixtures/plugin-updates/hung.sh"

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

# A timeout during plugin_update_execute reports partial failure and leaves a
# copied DMC install byte/layout unchanged.
PLUGIN="$SITE_PATH/wp-content/plugins/data-machine-code"
mkdir -p "$PLUGIN/inc"
printf '<?php\n/* Version: 1.0.0 */\n' > "$PLUGIN/data-machine-code.php"
printf 'homeboy-copied-bytes\n' > "$PLUGIN/inc/payload.txt"
before="$(python3 - "$PLUGIN" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
digest = hashlib.sha256()
for dirpath, dirs, files in os.walk(root, followlinks=False):
    dirs.sort()
    files.sort()
    digest.update(os.path.relpath(dirpath, root).encode())
    for name in dirs + files:
        path = os.path.join(dirpath, name)
        digest.update(os.path.relpath(path, root).encode())
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as handle:
                digest.update(handle.read())
print(digest.hexdigest())
PY
)"
wp_cmd() { printf '[{"name":"data-machine-code","status":"active","version":"1.0.0"}]\n'; }
hung_update() { plugin_update_run_phase data-machine-code copied-skip "$hung"; }

LOG=""
PLUGIN_UPDATE_STARTED_AT="$(date +%s)"
PLUGIN_UPDATE_FAILURES=()
PENDING_ITEMS=()
if plugin_update_execute data-machine-code hung_update; then
  fail "hung apply completed"
else
  status=$?
fi
[ "$status" -eq "$PLUGIN_UPDATE_EXIT_PARTIAL" ] || fail "partial apply did not return typed partial status"
plugin_update_verify_installed_plugins data-machine-code || true
after="$(python3 - "$PLUGIN" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
digest = hashlib.sha256()
for dirpath, dirs, files in os.walk(root, followlinks=False):
    dirs.sort()
    files.sort()
    digest.update(os.path.relpath(dirpath, root).encode())
    for name in dirs + files:
        path = os.path.join(dirpath, name)
        digest.update(os.path.relpath(path, root).encode())
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as handle:
                digest.update(handle.read())
print(digest.hexdigest())
PY
)"
[ "$before" = "$after" ] || fail "copied DMC mutated during a timed-out plugin update"
[ ! -e "$PLUGIN/.wp-coding-agents-releases" ] || fail "copied DMC was converted to .wp-coding-agents-releases"
case "$LOG" in *"installed-after version=1.0.0 active=yes"*"terminal=partial-failure"*) : ;; *) fail "partial terminal verification evidence missing" ;; esac

# Reconciliation preserves a mutation when the same plugin updater later times
# out, without classifying that record as completed.
LOG=""
PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS=1
PLUGIN_UPDATE_STARTED_AT="$(date +%s)"
reconciler_fixture_mutating_timeout() {
  PLUGIN_UPDATE_MUTATED=true
  plugin_update_run_phase data-machine-code reconciler-timeout "$hung"
}
reconciler_fixture_apply() { plugin_update_execute data-machine-code reconciler_fixture_mutating_timeout; }
reconciler_plan_reset
reconciler_plan_add plugins.data-machine-code plugins.reconcile.data-machine-code reconciler_fixture_apply
if reconciler_apply_plan; then
  fail "generic reconciler completed a timed-out plan"
else
  status=$?
fi
[ "$status" -eq "$PLUGIN_UPDATE_EXIT_PARTIAL" ] || fail "generic reconciler did not return partial status"
reconciler_print_partial_evidence
[ "${RECONCILER_CHANGED_RECORDS[*]}" = "plugins.data-machine-code" ] || fail "desired-state reconciler dropped or misreported the partial mutation"
[ "${#RECONCILER_COMPLETED_RECORDS[@]}" -eq 0 ] || fail "desired-state reconciler misclassified a partial mutation as completed"
case "$LOG" in
  *'record=plugins.data-machine-code operation=plugins.reconcile.data-machine-code apply=start'*'record=plugins.data-machine-code operation=plugins.reconcile.data-machine-code apply=partial changed=true'*'DESIRED_STATE_CHANGED_RECORDS=plugins.data-machine-code'*) : ;;
  *) fail "desired-state reconciler omitted partial mutation evidence" ;;
esac

# A later aggregate deadline must not inherit the changed outcome from a
# completed prior record when its own child never runs.
LOG=""
reconciler_fixture_first_changed() { reconciler_adapter_changed; }
reconciler_fixture_second_must_not_run() { : > "$TMP/aggregate-second-ran"; }
date() {
  case "${record:-}" in
    plugins.aggregate-first) printf '100\n' ;;
    plugins.aggregate-second) printf '101\n' ;;
    *) command date "$@" ;;
  esac
}
reconciler_plan_reset
reconciler_plan_add plugins.aggregate-first plugins.reconcile.aggregate-first reconciler_fixture_first_changed
reconciler_plan_add plugins.aggregate-second plugins.reconcile.aggregate-second reconciler_fixture_second_must_not_run
DESIRED_STATE_TOTAL_TIMEOUT_SECONDS=1
RECONCILER_STARTED_AT=100
if reconciler_apply_plan; then
  unset -f date
  fail "aggregate deadline plan completed"
else
  status=$?
fi
unset -f date
unset DESIRED_STATE_TOTAL_TIMEOUT_SECONDS
[ "$status" -eq "$PLUGIN_UPDATE_EXIT_PARTIAL" ] || fail "aggregate deadline did not return partial status"
[ ! -e "$TMP/aggregate-second-ran" ] || fail "aggregate deadline ran the second record"
[ "${RECONCILER_CHANGED_RECORDS[*]}" = "plugins.aggregate-first" ] || fail "aggregate deadline inherited a stale changed record"
[ "${RECONCILER_COMPLETED_RECORDS[*]}" = "plugins.aggregate-first" ] || fail "aggregate deadline completed the second record"
reconciler_print_partial_evidence
case "$LOG" in
  *'record=plugins.aggregate-second operation=plugins.reconcile.aggregate-second apply=timeout'*'DESIRED_STATE_CHANGED_RECORDS=plugins.aggregate-first'*) : ;;
  *) fail "desired-state reconciler omitted aggregate deadline evidence" ;;
esac

# A per-step child deadline likewise must not inherit a changed first record.
# This adapter hangs directly so the reconciler, rather than an inner plugin
# updater, owns the timeout and process-group cleanup.
LOG=""
reconciler_fixture_step_first_changed() { reconciler_adapter_changed; }
reconciler_fixture_step_hang() { : > "$TMP/step-hang-started"; sleep 30; }
reconciler_plan_reset
reconciler_plan_add plugins.step-first plugins.reconcile.step-first reconciler_fixture_step_first_changed
reconciler_plan_add plugins.step-second plugins.reconcile.step-second reconciler_fixture_step_hang
DESIRED_STATE_STEP_TIMEOUT_SECONDS=1
DESIRED_STATE_TOTAL_TIMEOUT_SECONDS=20
RECONCILER_STARTED_AT="$(date +%s)"
if reconciler_apply_plan; then
  fail "per-step deadline plan completed"
else
  status=$?
fi
unset DESIRED_STATE_STEP_TIMEOUT_SECONDS
unset DESIRED_STATE_TOTAL_TIMEOUT_SECONDS
[ "$status" -eq "$PLUGIN_UPDATE_EXIT_PARTIAL" ] || fail "per-step deadline did not return partial status"
[ -e "$TMP/step-hang-started" ] || fail "per-step deadline never started its child"
[ "${RECONCILER_CHANGED_RECORDS[*]}" = "plugins.step-first" ] || fail "per-step deadline inherited a stale changed record"
[ "${RECONCILER_COMPLETED_RECORDS[*]}" = "plugins.step-first" ] || fail "per-step deadline completed the hanging record"
reconciler_print_partial_evidence
case "$LOG" in
  *'record=plugins.step-second operation=plugins.reconcile.step-second apply=deadline-exceeded'*'record=plugins.step-second operation=plugins.reconcile.step-second apply=timeout timeout=1s'*'DESIRED_STATE_CHANGED_RECORDS=plugins.step-first'*) : ;;
  *) fail "desired-state reconciler omitted per-step deadline evidence" ;;
esac
case "$LOG" in *'aggregate_timeout='*) fail "per-step deadline used aggregate preflight" ;; esac

# Normalized profiles carry installation shape, never credential runtime input.
SITE_PATH="$TMP/site"
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
IS_STUDIO=false
KIMAKI_BOT_TOKEN=credential-must-not-appear
installation_profile_normalize "$INSTALLATION_OPERATION_PLUGINS_ONLY"
profile="$(installation_profile_record)"
case "$profile" in
  *credential-must-not-appear*|*KIMAKI_BOT_TOKEN*) fail "profile retained a credential" ;;
  *'operation=plugins-only'*'local=true'*'external_wordpress=false'*) : ;;
  *) fail "profile omitted plugins-only installation shape" ;;
esac

echo "plugin-upgrade-bounds tests passed"
