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

echo "plugin-upgrade-bounds tests passed"
