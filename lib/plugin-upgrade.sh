#!/bin/bash
# Bounded, observable execution for setup-installed plugin upgrades.

PLUGIN_UPDATE_EXIT_PARTIAL=75
PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS="${PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS:-120}"
PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS="${PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS:-480}"
PLUGIN_UPDATE_PROGRESS_SECONDS="${PLUGIN_UPDATE_PROGRESS_SECONDS:-10}"
PLUGIN_UPDATE_KILL_GRACE_SECONDS="${PLUGIN_UPDATE_KILL_GRACE_SECONDS:-2}"

plugin_update_positive_integer() {
  case "${1:-}" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

plugin_update_initialize() {
  plugin_update_positive_integer "$PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS" || PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS=120
  plugin_update_positive_integer "$PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS" || PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS=480
  plugin_update_positive_integer "$PLUGIN_UPDATE_PROGRESS_SECONDS" || PLUGIN_UPDATE_PROGRESS_SECONDS=10
  plugin_update_positive_integer "$PLUGIN_UPDATE_KILL_GRACE_SECONDS" || PLUGIN_UPDATE_KILL_GRACE_SECONDS=2
  PLUGIN_UPDATE_STARTED_AT="${PLUGIN_UPDATE_STARTED_AT:-$(date +%s)}"
  declare -p PLUGIN_UPDATE_FAILURES >/dev/null 2>&1 || PLUGIN_UPDATE_FAILURES=()
}

plugin_update_resume_command() {
  local script="${SCRIPT_DIR:-.}/upgrade.sh" path="${SITE_PATH:-}"
  printf '%q --plugins-only --wp-path %q' "$script" "$path"
}

plugin_update_command_string() {
  local arg rendered=""
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    rendered="${rendered}${rendered:+ }$arg"
  done
  printf '%s' "$rendered"
}

plugin_update_remaining_seconds() {
  local now elapsed remaining
  now="$(date +%s)"
  elapsed=$((now - PLUGIN_UPDATE_STARTED_AT))
  remaining=$((PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS - elapsed))
  [ "$remaining" -gt 0 ] || remaining=0
  printf '%s' "$remaining"
}

# Run one child command in its own process group. On timeout, only the process
# group created here is signalled; the evidence names the exact root command.
plugin_update_run_phase() {
  local slug="$1" phase="$2"
  shift 2
  local remaining timeout command temp_dir stdout_file stderr_file pid pgid
  local started now elapsed next_progress status restore_monitor=false

  plugin_update_initialize
  remaining="$(plugin_update_remaining_seconds)"
  if [ "$remaining" -eq 0 ]; then
    warn "[$slug] phase=$phase terminal=total-timeout elapsed=${PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS}s"
    warn "[$slug] resume: $(plugin_update_resume_command)"
    PLUGIN_PHASE_OUTPUT=""
    return 124
  fi
  timeout="$PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS"
  [ "$remaining" -ge "$timeout" ] || timeout="$remaining"
  command="$(plugin_update_command_string "$@")"
  temp_dir="$(mktemp -d)" || return 1
  stdout_file="$temp_dir/stdout"
  stderr_file="$temp_dir/stderr"

  log "[$slug] phase=$phase start timeout=${timeout}s command=$command"
  case "$-" in
    *m*) ;;
    *) set -m; restore_monitor=true ;;
  esac
  ( "$@" ) >"$stdout_file" 2>"$stderr_file" &
  pid=$!
  [ "$restore_monitor" = false ] || set +m
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  started="$(date +%s)"
  next_progress="$PLUGIN_UPDATE_PROGRESS_SECONDS"

  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - started))
    if [ "$elapsed" -ge "$timeout" ]; then
      warn "[$slug] phase=$phase terminal=timeout elapsed=${elapsed}s child_pid=$pid child_pgid=${pgid:-unknown} command=$command"
      local child
      child="$(ps -ax -o pid=,ppid=,pgid=,etime=,state=,command= 2>/dev/null | awk -v group="${pgid:-$pid}" '$3 == group')"
      [ -z "$child" ] || warn "[$slug] timed-out-child: $child"
      if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
      sleep "$PLUGIN_UPDATE_KILL_GRACE_SECONDS"
      if kill -0 "$pid" 2>/dev/null; then
        if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
          kill -KILL -- "-$pgid" 2>/dev/null || true
        else
          kill -KILL "$pid" 2>/dev/null || true
        fi
      fi
      wait "$pid" 2>/dev/null || true
      [ ! -s "$stderr_file" ] || while IFS= read -r line; do warn "[$slug] child-stderr: $line"; done < "$stderr_file"
      PLUGIN_PHASE_OUTPUT=""
      warn "[$slug] resume: $(plugin_update_resume_command)"
      rm -rf "$temp_dir"
      return 124
    fi
    if [ "$elapsed" -ge "$next_progress" ]; then
      log "[$slug] phase=$phase progress elapsed=${elapsed}s child_pid=$pid child_pgid=${pgid:-unknown}"
      next_progress=$((next_progress + PLUGIN_UPDATE_PROGRESS_SECONDS))
    fi
    sleep 1
  done

  if wait "$pid"; then status=0; else status=$?; fi
  now="$(date +%s)"
  elapsed=$((now - started))
  PLUGIN_PHASE_OUTPUT="$(cat "$stdout_file")"
  if [ "$status" -ne 0 ]; then
    [ ! -s "$stderr_file" ] || while IFS= read -r line; do warn "[$slug] child-stderr: $line"; done < "$stderr_file"
    warn "[$slug] phase=$phase terminal=failed status=$status elapsed=${elapsed}s command=$command"
    warn "[$slug] resume: $(plugin_update_resume_command)"
  else
    log "[$slug] phase=$phase terminal=complete elapsed=${elapsed}s"
  fi
  rm -rf "$temp_dir"
  return "$status"
}

plugin_update_local_version() {
  local slug="$1" file
  case "$slug" in
    data-machine) file="$SITE_PATH/wp-content/plugins/$slug/data-machine.php" ;;
    wp-codebox) file="$SITE_PATH/wp-content/plugins/$slug/wp-codebox.php" ;;
    *) return 1 ;;
  esac
  [ -f "$file" ] || return 1
  grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' "$file" | sed -E 's/.*Version:[[:space:]]*([^[:space:]]+).*/\1/'
}

plugin_update_state_from_json() {
  local json="$1" slug="$2"
  PLUGIN_STATE_TUPLE="$(PLUGIN_STATES_JSON="$json" PLUGIN_STATE_SLUG="$slug" python3 <<'PY'
import json
import os

slug = os.environ['PLUGIN_STATE_SLUG']
raw = os.environ['PLUGIN_STATES_JSON']
decoder = json.JSONDecoder()
plugins = None
for offset, character in enumerate(raw):
    if character != '[':
        continue
    try:
        candidate, _ = decoder.raw_decode(raw[offset:])
    except json.JSONDecodeError:
        continue
    if isinstance(candidate, list):
        plugins = candidate
        break
if plugins is None:
    raise SystemExit(2)
for plugin in plugins:
    if not isinstance(plugin, dict):
        continue
    if plugin.get('name') == slug:
        print('%s\t%s' % (plugin.get('version', ''), plugin.get('status', '')))
        raise SystemExit(0)
raise SystemExit(1)
PY
)"
}

plugin_update_record_failure() {
  local slug="$1" type="$2" status="$3"
  PLUGIN_UPDATE_FAILURES+=("$slug type=$type status=$status")
  PENDING_ITEMS+=("$slug plugin upgrade partial ($type; resume: $(plugin_update_resume_command))")
}

plugin_update_execute() {
  local slug="$1"
  shift
  local before_version="unknown" after_version="unknown"
  local update_status=0

  plugin_update_initialize
  before_version="$(plugin_update_local_version "$slug" 2>/dev/null || printf unknown)"
  log "[$slug] installed-before version=${before_version:-unknown} activation=preserved-without-database-mutation"

  # Read by updater modules sourced into the same shell.
  # shellcheck disable=SC2034
  PLUGIN_UPDATE_ACTIVE=true
  # Updaters set this only after their managed plugin state changes.
  # shellcheck disable=SC2034
  PLUGIN_UPDATE_MUTATED=false
  if "$@"; then update_status=0; else update_status=$?; fi
  # shellcheck disable=SC2034
  PLUGIN_UPDATE_ACTIVE=false

  after_version="$(plugin_update_local_version "$slug" 2>/dev/null || printf unknown)"

  if [ "$update_status" -ne 0 ]; then
    plugin_update_record_failure "$slug" "$( [ "$update_status" -eq 124 ] && printf timeout || printf command-failure )" "$update_status"
  fi

  # Preserve an updater-reported mutation for reconciliation, including a
  # later bounded-step failure.
  if [ "$PLUGIN_UPDATE_MUTATED" = true ] \
    && declare -F reconciler_adapter_changed >/dev/null 2>&1; then
    reconciler_adapter_changed
  fi

  if [ "$update_status" -eq 0 ]; then
    log "[$slug] apply-terminal=complete version=${after_version:-unknown}"
    return 0
  fi
  warn "[$slug] apply-terminal=partial-failure update_status=$update_status"
  return "$PLUGIN_UPDATE_EXIT_PARTIAL"
}

plugin_update_slug_failed() {
  local slug="$1" failure
  for failure in "${PLUGIN_UPDATE_FAILURES[@]:-}"; do
    case "$failure" in "$slug "*) return 0 ;; esac
  done
  return 1
}

plugin_update_verify_installed_plugins() {
  local slugs=("$@") slug plugin_dir tuple version status active file_version phase_status=0 failed=false
  if [ "${DRY_RUN:-false}" = true ]; then
    for slug in "${slugs[@]}"; do
      [ -d "$SITE_PATH/wp-content/plugins/$slug" ] || continue
      log "[$slug] terminal=dry-run version=$(plugin_update_local_version "$slug" 2>/dev/null || printf unknown) activation=unchanged"
    done
    return 0
  fi

  if plugin_update_run_phase plugins wordpress-terminal-verification wp_cmd plugin list --fields=name,status,version --format=json --skip-plugins; then
    PLUGIN_STATES_AFTER_JSON="$PLUGIN_PHASE_OUTPUT"
  else
    phase_status=$?
    for slug in "${slugs[@]}"; do
      [ -d "$SITE_PATH/wp-content/plugins/$slug" ] || continue
      plugin_update_record_failure "$slug" verification "$phase_status"
      warn "[$slug] terminal=partial-failure verification_status=$phase_status"
    done
    return "$PLUGIN_UPDATE_EXIT_PARTIAL"
  fi

  for slug in "${slugs[@]}"; do
    plugin_dir="$SITE_PATH/wp-content/plugins/$slug"
    [ -d "$plugin_dir" ] || continue
    if plugin_update_state_from_json "$PLUGIN_STATES_AFTER_JSON" "$slug"; then
      tuple="$PLUGIN_STATE_TUPLE"
      IFS=$'\t' read -r version status <<< "$tuple"
    else
      version=""; status="missing"
    fi
    file_version="$(plugin_update_local_version "$slug" 2>/dev/null || true)"
    case "$status" in active|active-network) active=yes ;; *) active=no ;; esac
    log "[$slug] installed-after version=${version:-missing} active=$active file_version=${file_version:-missing}"
    if [ -z "$version" ] || [ "$version" != "$file_version" ] || [ "$status" = missing ]; then
      plugin_update_record_failure "$slug" verification 1
      failed=true
    fi
    if plugin_update_slug_failed "$slug"; then
      warn "[$slug] terminal=partial-failure version=${version:-missing} status=$status"
    else
      log "[$slug] terminal=complete version=$version status=$status"
    fi
  done
  [ "$failed" = false ]
}

plugin_update_print_terminal_summary() {
  local failure
  if [ "${#PLUGIN_UPDATE_FAILURES[@]}" -gt 0 ]; then
    warn "PLUGIN_UPGRADE_RESULT=partial_failure exit=$PLUGIN_UPDATE_EXIT_PARTIAL"
    for failure in "${PLUGIN_UPDATE_FAILURES[@]}"; do warn "  $failure"; done
  else
    log "PLUGIN_UPGRADE_RESULT=complete"
  fi
}
