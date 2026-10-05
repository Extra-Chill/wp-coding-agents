#!/bin/bash
# Regression coverage for #458: terminal plugin verification must survive WP-CLI
# diagnostic preambles (for example PHP 8.5 deprecation notices) and non-JSON
# output (for example a database-unavailable error) without shell evaluation
# errors, and a verification that could not run must stay distinguishable from
# both a completed verification and a successful release-pointer update.
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

mkdir -p "$SITE_PATH/wp-content/plugins/data-machine"
printf '<?php\n/**\n * Version: 1.2.3\n */\n' > "$SITE_PATH/wp-content/plugins/data-machine/data-machine.php"

# A PHP 8.5 deprecation preamble before the plugin JSON still yields state.
PHP85_PREAMBLE=$'PHP Deprecated:  str_replace(): Passing null to parameter #1 of type array is deprecated in phar:///wp-cli.phar on line 42\n[{"name":"data-machine","status":"active","version":"1.2.3"}]'
plugin_update_state_from_json "$PHP85_PREAMBLE" data-machine || fail "preamble-bearing plugin JSON was refused"
[ "$PLUGIN_STATE_TUPLE" = $'1.2.3\tactive' ] || fail "preamble-bearing plugin JSON returned the wrong state"

# A diagnostic preamble before a JSON object document parses the same way.
plugin_update_state_from_json $'Deprecated: fixture preamble\n{"plugins":[{"name":"data-machine","status":"active-network","version":"2.0.0"}]}' data-machine || fail "preamble-bearing plugin object was refused"
[ "$PLUGIN_STATE_TUPLE" = $'2.0.0\tactive-network' ] || fail "preamble-bearing plugin object returned the wrong state"

plugin_update_state_from_json '{"name":"data-machine","status":"inactive","version":"3.0.0"}' data-machine || fail "single plugin object was refused"
[ "$PLUGIN_STATE_TUPLE" = $'3.0.0\tinactive' ] || fail "single plugin object returned the wrong state"

# Database-unavailable output carries no JSON document: the parser must refuse
# it with the typed no-valid-JSON status instead of raising or emitting values.
parse_status=0
if plugin_update_state_from_json $'Error: Error establishing a database connection' data-machine; then
  fail "database-unavailable output was accepted"
else
  parse_status=$?
fi
[ "$parse_status" -eq "$PLUGIN_UPDATE_PARSE_NO_VALID_JSON" ] || fail "database-unavailable output returned $parse_status instead of the typed no-valid-JSON status"
[ -z "$PLUGIN_STATE_TUPLE" ] || fail "database-unavailable output leaked a state tuple"

# Hostile diagnostics never reach shell evaluation: the parser only reports
# statuses, and no command substitution or backtick content is executed.
parse_status=0
if plugin_update_state_from_json $'PHP Notice: $(should-not-run)\n`should-not-run` [also not json' data-machine; then
  fail "hostile non-JSON output was accepted"
else
  parse_status=$?
fi
[ "$parse_status" -eq "$PLUGIN_UPDATE_PARSE_NO_VALID_JSON" ] || fail "hostile output returned $parse_status instead of the typed no-valid-JSON status"
[ ! -e "$TMP/should-not-run" ] || fail "hostile diagnostics were evaluated by the shell"

# The public plugins-only verification workflow completes across a
# diagnostic-prefixed plugin list when versions match.
LOG=""
PLUGIN_UPDATE_FAILURES=()
PENDING_ITEMS=()
wp_cmd() { printf '%s\n' "$PHP85_PREAMBLE"; }
plugin_update_verify_installed_plugins data-machine || fail "preamble-bearing terminal verification failed"
[ "${#PLUGIN_UPDATE_FAILURES[@]}" -eq 0 ] || fail "preamble-bearing terminal verification recorded failures"
case "$LOG" in
  *"[data-machine] terminal=complete version=1.2.3 status=active"*) : ;;
  *) fail "preamble-bearing terminal verification omitted complete evidence" ;;
esac
plugin_update_print_terminal_summary
case "$LOG" in *"PLUGIN_UPGRADE_RESULT=complete"*) : ;; *) fail "preamble-bearing verification did not report complete" ;; esac

# The same workflow against database-unavailable output records a typed
# verification-unavailable failure rather than an empty version value.
LOG=""
PLUGIN_UPDATE_FAILURES=()
PENDING_ITEMS=()
wp_cmd() { printf 'Error: Error establishing a database connection\n'; }
verify_status=0
if plugin_update_verify_installed_plugins data-machine; then
  fail "database-unavailable terminal verification completed"
else
  verify_status=$?
fi
[ "$verify_status" -eq 1 ] || fail "database-unavailable verification returned $verify_status instead of a verification refusal"
plugin_update_print_terminal_summary
case "$LOG" in
  *"terminal=verification-unavailable evidence=no-valid-json"*"PLUGIN_UPGRADE_RESULT=partial_failure exit=75"*"data-machine type=verification-unavailable status=2"*) : ;;
  *) fail "database-unavailable verification omitted typed verification-unavailable evidence" ;;
esac
case "$LOG" in *"installed-after version=missing"*) fail "database-unavailable verification emitted empty version values" ;; esac

# A verification that ran and genuinely missed the slug keeps its own type.
LOG=""
PLUGIN_UPDATE_FAILURES=()
PENDING_ITEMS=()
wp_cmd() { printf '[{"name":"wp-codebox","status":"active","version":"1.0.0"}]\n'; }
if plugin_update_verify_installed_plugins data-machine; then
  fail "missing-slug terminal verification completed"
else
  verify_status=$?
fi
[ "$verify_status" -eq 1 ] || fail "missing-slug verification returned $verify_status instead of a verification refusal"
[ "${PLUGIN_UPDATE_FAILURES[*]}" = "data-machine type=verification status=1" ] || fail "missing-slug verification was not recorded as a genuine verification failure"

# A successful release-pointer update stays distinguishable from verification
# that could not run: the apply terminal completes, and only the verification
# record is typed as unavailable.
LOG=""
PLUGIN_UPDATE_FAILURES=()
PENDING_ITEMS=()
release_pointer_fixture() { printf 'git checkout --detach v1.2.3\n'; }
plugin_update_execute data-machine release_pointer_fixture || fail "successful release-pointer update failed"
case "$LOG" in
  *"[data-machine] apply-terminal=complete version=1.2.3"*) : ;;
  *) fail "successful release-pointer update omitted complete apply evidence" ;;
esac
wp_cmd() { printf 'Error: Error establishing a database connection\n'; }
if plugin_update_verify_installed_plugins data-machine; then
  fail "database-unavailable terminal verification completed"
fi
case "$LOG" in
  *"[data-machine] apply-terminal=complete version=1.2.3"*"terminal=verification-unavailable evidence=no-valid-json"*) : ;;
  *) fail "successful release-pointer update is not distinguishable from verification that could not run" ;;
esac
case "$LOG" in *"apply-terminal=partial-failure"*) fail "successful release-pointer update was misreported as partial" ;; esac
[ "${PLUGIN_UPDATE_FAILURES[*]}" = "data-machine type=verification-unavailable status=2" ] || fail "verification-unavailable record was not the only failure after a successful update"

echo "plugin-terminal-verification tests passed"
