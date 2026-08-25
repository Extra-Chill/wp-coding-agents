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
  declare -p PLUGIN_UPDATE_POINTER_EVIDENCE >/dev/null 2>&1 || PLUGIN_UPDATE_POINTER_EVIDENCE=()
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
    data-machine-code) file="$SITE_PATH/wp-content/plugins/$slug/data-machine-code.php" ;;
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
for plugin in json.loads(os.environ['PLUGIN_STATES_JSON']):
    if plugin.get('name') == slug:
        print('%s\t%s' % (plugin.get('version', ''), plugin.get('status', '')))
        raise SystemExit(0)
raise SystemExit(1)
PY
)"
}

plugin_update_release_pointer() {
  local slug="$1" plugin_dir="$SITE_PATH/wp-content/plugins/$1"
  if [ "$slug" = data-machine-code ] && [ ! -d "$plugin_dir/.git" ]; then
    readlink "$plugin_dir/.wp-coding-agents-release-current" 2>/dev/null || printf 'missing'
  else
    printf 'not-applicable'
  fi
}

plugin_update_local_release_valid() {
  local slug="$1" plugin_dir="$SITE_PATH/wp-content/plugins/$1"
  [ "$slug" = data-machine-code ] || return 0
  [ -d "$plugin_dir/.git" ] && return 0
  local root_version pointer_version provenance
  root_version="$(plugin_update_local_version "$slug" 2>/dev/null || true)"
  pointer_version="$(grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' "$plugin_dir/.wp-coding-agents-release-current/data-machine-code.php" 2>/dev/null | sed -E 's/.*Version:[[:space:]]*([^[:space:]]+).*/\1/' || true)"
  provenance="$plugin_dir/.wp-coding-agents-release-current/.wp-coding-agents-managed-release.json"
  [ -n "$root_version" ] && [ "$pointer_version" = "$root_version" ] && [ -f "$provenance" ] && grep -Fq "\"version\":\"$root_version\"" "$provenance"
}

plugin_update_record_failure() {
  local slug="$1" type="$2" status="$3"
  PLUGIN_UPDATE_FAILURES+=("$slug type=$type status=$status")
  PENDING_ITEMS+=("$slug plugin upgrade partial ($type; resume: $(plugin_update_resume_command))")
}

plugin_update_execute() {
  local slug="$1"
  shift
  local plugin_dir="$SITE_PATH/wp-content/plugins/$slug"
  local before_version="unknown" after_version="unknown"
  local before_pointer after_pointer update_status=0

  plugin_update_initialize
  before_pointer="$(plugin_update_release_pointer "$slug")"
  before_version="$(plugin_update_local_version "$slug" 2>/dev/null || printf unknown)"
  log "[$slug] installed-before version=${before_version:-unknown} activation=preserved-without-database-mutation"

  # Read by updater modules sourced into the same shell.
  # shellcheck disable=SC2034
  PLUGIN_UPDATE_ACTIVE=true
  if "$@"; then update_status=0; else update_status=$?; fi
  # shellcheck disable=SC2034
  PLUGIN_UPDATE_ACTIVE=false

  after_pointer="$(plugin_update_release_pointer "$slug")"
  PLUGIN_UPDATE_POINTER_EVIDENCE+=("$slug changed=$( [ "$before_pointer" = "$after_pointer" ] && printf no || printf yes ) before=$before_pointer after=$after_pointer")
  after_version="$(plugin_update_local_version "$slug" 2>/dev/null || printf unknown)"

  if [ "$update_status" -ne 0 ]; then
    plugin_update_record_failure "$slug" "$( [ "$update_status" -eq 124 ] && printf timeout || printf command-failure )" "$update_status"
  fi

  if [ "$update_status" -eq 0 ]; then
    log "[$slug] apply-terminal=complete version=${after_version:-unknown} release_pointer_changed=$( [ "$before_pointer" = "$after_pointer" ] && printf no || printf yes )"
    return 0
  fi
  warn "[$slug] apply-terminal=partial-failure update_status=$update_status release_pointer_changed=$( [ "$before_pointer" = "$after_pointer" ] && printf no || printf yes )"
  return "$PLUGIN_UPDATE_EXIT_PARTIAL"
}

plugin_update_slug_failed() {
  local slug="$1" failure
  for failure in "${PLUGIN_UPDATE_FAILURES[@]:-}"; do
    case "$failure" in "$slug "*) return 0 ;; esac
  done
  return 1
}

plugin_update_pointer_changed() {
  local slug="$1" evidence
  for evidence in "${PLUGIN_UPDATE_POINTER_EVIDENCE[@]:-}"; do
    case "$evidence" in "$slug "*) case "$evidence" in *" changed=yes "*) printf yes ;; *) printf no ;; esac; return 0 ;; esac
  done
  printf no
}

plugin_update_verify_installed_plugins() {
  local slugs=("$@") slug plugin_dir tuple version status file_version phase_status=0 failed=false
  if [ "${DRY_RUN:-false}" = true ]; then
    for slug in "${slugs[@]}"; do
      [ -d "$SITE_PATH/wp-content/plugins/$slug" ] || continue
      log "[$slug] terminal=dry-run version=$(plugin_update_local_version "$slug" 2>/dev/null || printf unknown) activation=unchanged"
    done
    return 0
  fi

  for slug in "${slugs[@]}"; do
    [ -d "$SITE_PATH/wp-content/plugins/$slug" ] || continue
    if plugin_update_local_release_valid "$slug"; then
      [ "$slug" != data-machine-code ] || log "[$slug] release-pointer-verification=complete version=$(plugin_update_local_version "$slug") provenance=present"
    else
      plugin_update_record_failure "$slug" release-pointer-verification 1
      warn "[$slug] release-pointer-verification=failed"
      failed=true
    fi
  done

  if plugin_update_run_phase plugins wordpress-terminal-verification wp_cmd plugin list --fields=name,status,version --format=json --skip-plugins; then
    PLUGIN_STATES_AFTER_JSON="$PLUGIN_PHASE_OUTPUT"
  else
    phase_status=$?
    for slug in "${slugs[@]}"; do
      [ -d "$SITE_PATH/wp-content/plugins/$slug" ] || continue
      plugin_update_record_failure "$slug" verification "$phase_status"
      warn "[$slug] terminal=partial-failure verification_status=$phase_status release_pointer_changed=$(plugin_update_pointer_changed "$slug")"
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
    log "[$slug] installed-after version=${version:-missing} active=$( case "$status" in active|active-network) printf yes ;; *) printf no ;; esac ) file_version=${file_version:-missing}"
    if [ -z "$version" ] || [ "$version" != "$file_version" ] || [ "$status" = missing ]; then
      plugin_update_record_failure "$slug" verification 1
      failed=true
    fi
    if plugin_update_slug_failed "$slug"; then
      warn "[$slug] terminal=partial-failure version=${version:-missing} status=$status release_pointer_changed=$(plugin_update_pointer_changed "$slug")"
    else
      log "[$slug] terminal=complete version=$version status=$status release_pointer_changed=$(plugin_update_pointer_changed "$slug")"
    fi
  done
  [ "$failed" = false ]
}

plugin_update_print_terminal_summary() {
  local evidence failure
  log "Plugin release-pointer evidence:"
  for evidence in "${PLUGIN_UPDATE_POINTER_EVIDENCE[@]:-}"; do
    [ -z "$evidence" ] || log "  $evidence"
  done
  if [ "${#PLUGIN_UPDATE_FAILURES[@]}" -gt 0 ]; then
    warn "PLUGIN_UPGRADE_RESULT=partial_failure exit=$PLUGIN_UPDATE_EXIT_PARTIAL"
    for failure in "${PLUGIN_UPDATE_FAILURES[@]}"; do warn "  $failure"; done
  else
    log "PLUGIN_UPGRADE_RESULT=complete"
  fi
}
