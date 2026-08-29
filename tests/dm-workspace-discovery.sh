#!/bin/bash
# tests/dm-workspace-discovery.sh — bounded canonical DMC workspace discovery.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php"

export SITE_PATH
export DRY_RUN=false
export WP_CMD="studio wp"
export WP_ROOT_FLAG=""

MODE=success
WP_CALLS_FILE="$TMP/wp-calls"
CHILD_PID_FILE="$TMP/child.pid"
DESCENDANT_PID_FILE="$TMP/descendant.pid"
export WP_CALLS_FILE CHILD_PID_FILE DESCENDANT_PID_FILE

source "$SCRIPT_DIR/lib/common.sh"
log() { printf '%s\n' "$1"; }
warn() { printf '%s\n' "$1"; }

wp_cmd() {
  printf 'call\n' >> "$WP_CALLS_FILE"
  if [ "$*" != "datamachine-code workspace path" ]; then
    echo "unexpected wp_cmd call: $*" >&2
    return 1
  fi
  case "$MODE" in
    success)
      sleep 0.2
      printf '%s\n' "$TMP/Developer"
      ;;
    diagnostic_prefix)
      printf '\nDeprecated: Case statements followed by a semicolon are deprecated.\n%s\n' "$TMP/Developer"
      ;;
    arbitrary_prefix)
      printf 'unexpected output\n%s\n' "$TMP/Developer"
      ;;
    ambiguous)
      printf '%s\n%s\n' "$TMP/Developer" "$TMP/other-workspace"
      ;;
    failure)
      echo "DMC_ERROR_CODE=workspace_locked: sqlite busy" >&2
      return 73
      ;;
    hang)
      /bin/sh -c 'printf "%s\n" "$$" > "$CHILD_PID_FILE"; sleep 30 & printf "%s\n" "$!" > "$DESCENDANT_PID_FILE"; wait'
      ;;
  esac
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/data-machine.sh"

DM_WORKSPACE_DIR="$TMP/.datamachine/workspace"
DATAMACHINE_WORKSPACE_PATH=""
DM_WORKSPACE_DISCOVERY_TIMEOUT_SECONDS=2
discover_dm_workspace_dir
if [ "$DM_WORKSPACE_DIR" != "$TMP/Developer" ]; then
  echo "FAIL: slow canonical DMC workspace was not discovered: $DM_WORKSPACE_DIR"
  exit 1
fi

MODE=diagnostic_prefix
DM_WORKSPACE_DIR=""
discover_dm_workspace_dir
if [ "$DM_WORKSPACE_DIR" != "$TMP/Developer" ]; then
  echo "FAIL: canonical DMC workspace with a PHP diagnostic prefix was not discovered: $DM_WORKSPACE_DIR"
  exit 1
fi

for invalid_mode in arbitrary_prefix ambiguous; do
  MODE="$invalid_mode"
  DM_WORKSPACE_DIR="$TMP/guessed-workspace"
  set +e
  discover_dm_workspace_dir >"$TMP/$invalid_mode.out" 2>"$TMP/$invalid_mode.err"
  invalid_status=$?
  set -e
  if [ "$invalid_status" -eq 0 ] || [ -n "$DM_WORKSPACE_DIR" ]; then
    echo "FAIL: $invalid_mode workspace output was accepted: $DM_WORKSPACE_DIR"
    exit 1
  fi
done

DATAMACHINE_WORKSPACE_PATH="$TMP/explicit-workspace"
DM_WORKSPACE_DIR="$TMP/Developer"
rm -f "$WP_CALLS_FILE"
discover_dm_workspace_dir
if [ "$DM_WORKSPACE_DIR" != "$TMP/explicit-workspace" ]; then
  echo "FAIL: explicit workspace path was not authoritative: $DM_WORKSPACE_DIR"
  exit 1
fi
if [ -e "$WP_CALLS_FILE" ]; then
  echo "FAIL: explicit workspace path still invoked authoritative discovery"
  exit 1
fi

DATAMACHINE_WORKSPACE_PATH=""
DM_WORKSPACE_DIR="$TMP/guessed-workspace"
MODE=failure
set +e
discover_dm_workspace_dir >"$TMP/failure.out" 2>"$TMP/failure.err"
failure_status=$?
set -e
failure_output="$(cat "$TMP/failure.out")$(cat "$TMP/failure.err")"
if [ "$failure_status" -ne 73 ] || [[ "$failure_output" != *"DMC_ERROR_CODE=workspace_locked: sqlite busy"* ]]; then
  echo "FAIL: nonzero discovery did not preserve status and stderr: status=$failure_status output=$failure_output"
  exit 1
fi
if [[ "$failure_output" != *"studio wp datamachine-code workspace path"*"--path=$SITE_PATH"* ]]; then
  echo "FAIL: discovery failure did not name the replay command: $failure_output"
  exit 1
fi
if [ -n "$DM_WORKSPACE_DIR" ]; then
  echo "FAIL: failed authoritative discovery retained guessed workspace: $DM_WORKSPACE_DIR"
  exit 1
fi

MODE=hang
DM_WORKSPACE_DIR="$TMP/guessed-workspace"
DM_WORKSPACE_DISCOVERY_TIMEOUT_SECONDS=1
started="$(python3 -c 'import time; print(time.monotonic())')"
set +e
discover_dm_workspace_dir >"$TMP/timeout.out" 2>"$TMP/timeout.err"
timeout_status=$?
set -e
elapsed="$(python3 -c 'import sys, time; print(time.monotonic() - float(sys.argv[1]))' "$started")"
timeout_output="$(cat "$TMP/timeout.out")$(cat "$TMP/timeout.err")"
if [ "$timeout_status" -ne 124 ] || ! python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 2.5 else 1)' "$elapsed"; then
  echo "FAIL: hanging discovery was not bounded: status=$timeout_status elapsed=${elapsed}s"
  exit 1
fi
if [[ "$timeout_output" != *"timeout: 1s, elapsed: 0s"* ]] || [[ "$timeout_output" != *"timed out after 1s"* ]]; then
  echo "FAIL: timeout diagnostic omitted phase timing: $timeout_output"
  exit 1
fi
if [[ "$timeout_output" != *"studio wp datamachine-code workspace path"*"--path=$SITE_PATH"* ]]; then
  echo "FAIL: timeout diagnostic did not name the replay command: $timeout_output"
  exit 1
fi

for pid_file in "$CHILD_PID_FILE" "$DESCENDANT_PID_FILE"; do
  if [ ! -s "$pid_file" ]; then
    echo "FAIL: hanging fixture did not record process in $pid_file"
    exit 1
  fi
  pid="$(cat "$pid_file")"
  attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: timed out discovery left process $pid alive"
    exit 1
  fi
done

echo "PASS: tests/dm-workspace-discovery.sh"
