#!/bin/bash
# tests/bridge-reconcile-progress.sh — the bounded bridge step extends its
# deadline while it makes visible progress, and failed records are tracked
# so callers can gate dependents (#725).
#
# A cold global `npm install -g` of the pinned Roadie tarball took 514s on
# macOS against the fixed 420s bridge step budget: the step was killed while
# npm was steadily reifying packages, leaving the old release installed.
# The bounded runner now advertises a progress file; a child that keeps
# touching it earns deadline extensions (capped hard), and a child that
# stalls stops earning them.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/desired-state-reconciler.sh"

log() { :; }
error() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
WARN_LOG="$TMP/warn.log"
warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }

# Keep every bound tight so the suite stays fast; the aggregate deadline must
# be reset because the fixed 480s default would clamp these steps.
DESIRED_STATE_TOTAL_TIMEOUT_SECONDS=60
DESIRED_STATE_STEP_TIMEOUT_SECONDS=120
DESIRED_STATE_PROGRESS_GRACE_SECONDS=3
DESIRED_STATE_PROGRESS_MAX_SECONDS=8
PLUGIN_UPDATE_KILL_GRACE_SECONDS=0

# A step that keeps heartbeating survives well past its fixed deadline and
# completes successfully.
slow_progress_step() {
  local n=0
  while [ "$n" -lt 5 ]; do
    sleep 1
    n=$((n + 1))
    touch "$RECONCILER_STEP_PROGRESS_FILE"
  done
}
reconciler_plan_reset
reconciler_plan_add fixture.progress fixture slow_progress_step "" 2
started="$(date +%s)"
reconciler_apply_plan >/dev/null 2>&1 || error "heartbeating step was killed at its fixed deadline"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -ge 5 ] || error "heartbeating step finished before it could have been extended (${elapsed}s)"
grep -q '=progress' "$WARN_LOG" || error "extension was not logged"
grep -q '=deadline-exceeded' "$WARN_LOG" && error "heartbeating step was reported as deadline-exceeded"

# A step that heartbeats early and then stalls is killed once the heartbeat
# goes stale — extension must be re-earned by fresh progress.
stall_after_progress_step() {
  touch "$RECONCILER_STEP_PROGRESS_FILE"
  sleep 30
}
: > "$WARN_LOG"
reconciler_plan_reset
reconciler_plan_add fixture.stall fixture stall_after_progress_step "" 2
started="$(date +%s)"
reconciler_apply_plan >/dev/null 2>&1 && error "stalled step unexpectedly completed"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] || error "stalled step was not killed after its heartbeat went stale (${elapsed}s)"
grep -q '=deadline-exceeded' "$WARN_LOG" || error "stalled step did not report deadline-exceeded"

# The extension is hard-capped: a step that heartbeats forever still
# terminates at DESIRED_STATE_PROGRESS_MAX_SECONDS.
forever_progress_step() {
  while :; do
    touch "$RECONCILER_STEP_PROGRESS_FILE"
    sleep 1
  done
}
: > "$WARN_LOG"
reconciler_plan_reset
reconciler_plan_add fixture.forever fixture forever_progress_step "" 2
started="$(date +%s)"
reconciler_apply_plan >/dev/null 2>&1 && error "forever-heartbeating step unexpectedly completed"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] || error "progress cap did not terminate the forever step (${elapsed}s)"

# A step with no heartbeat at all behaves exactly as before the mechanism
# existed: killed at the fixed step deadline.
silent_step() { sleep 30; }
: > "$WARN_LOG"
reconciler_plan_reset
reconciler_plan_add fixture.silent fixture silent_step "" 2
started="$(date +%s)"
reconciler_apply_plan >/dev/null 2>&1 && error "silent step unexpectedly completed"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 6 ] || error "silent step was not killed at its fixed deadline (${elapsed}s)"
grep -q '=progress' "$WARN_LOG" && error "silent step was extended without a heartbeat"
rm -f "$WARN_LOG"

# Apply and verify failures are recorded per record so callers (upgrade.sh)
# can gate the steps that assume the failed component's new state.
apply_fail() { return 3; }
verify_fail() { return 4; }
apply_ok() { :; }
reconciler_plan_reset
reconciler_plan_add fixture.apply-failed fixture apply_fail
reconciler_plan_add fixture.verify-failed fixture apply_ok verify_fail
reconciler_apply_plan >/dev/null 2>&1 || true
case " ${RECONCILER_FAILED_RECORDS[*]:-} " in
  *' fixture.apply-failed '*) : ;;
  *) error "apply failure was not recorded in RECONCILER_FAILED_RECORDS" ;;
esac
case " ${RECONCILER_FAILED_RECORDS[*]:-} " in
  *' fixture.verify-failed '*) : ;;
  *) error "verify failure was not recorded in RECONCILER_FAILED_RECORDS" ;;
esac
case " ${RECONCILER_COMPLETED_RECORDS[*]:-} " in
  *' fixture.verify-failed '*) error "failed verification was recorded as completed" ;;
esac
reconciler_plan_reset
[ "${#RECONCILER_FAILED_RECORDS[@]}" -eq 0 ] || error "plan reset did not clear RECONCILER_FAILED_RECORDS"

echo "PASS: tests/bridge-reconcile-progress.sh"
