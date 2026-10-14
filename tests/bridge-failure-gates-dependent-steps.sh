#!/bin/bash
# tests/bridge-failure-gates-dependent-steps.sh — a failed bridge record
# gates the upgrade steps that assume the new Roadie (#725).
#
# The bridge reconcile step owns the pinned Roadie install. When it fails
# (deadline-exceeded during a cold npm install, #725), the installed bridge
# may still be the previous release while the config on disk has already
# been written for the new one:
#
#   - the opencode.json repair rewrites model routes toward `roadie/*`
#     provider routes the installed release cannot serve,
#   - the retired claude-code-auth plugin is shed.
#
# Both live in check_opencode_json_drift, so the whole phase must skip —
# and print_summary must withhold the restart hint, because restarting the
# old Roadie would point every session at routes it cannot serve.
#
# The functions under test live in upgrade.sh, which executes on source, so
# they are exercised by extracting their source, the same technique as
# tests/upgrade-opencode-auth-plugin-sync.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$SCRIPT_DIR/upgrade.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

require_source() {
  local pattern="$1" description="$2"
  if ! grep -Fq "$pattern" "$UPGRADE"; then
    echo "FAIL: missing $description" >&2
    echo "pattern: $pattern" >&2
    exit 1
  fi
}

require_source 'BRIDGE_RECONCILE_FAILED=false' "bridge-failure gate accumulator"
require_source "*' bridges.'*) BRIDGE_RECONCILE_FAILED=true ;;" "bridge-record failure detection in the execute block"
require_source 'BRIDGE_RECONCILE_FAILED:-false' "gate consulted before dependent steps"

# Extract check_opencode_json_drift and _print_bridge_restart_hint without
# executing the rest of upgrade.sh.
source <(python3 - "$UPGRADE" <<'PY'
import sys
source = open(sys.argv[1]).read()
start = source.index('check_opencode_json_drift() {')
end = source.index('# Phase 4:', start)
print(source[start:end])
start = source.index('_print_bridge_restart_hint() {')
end = source.index('_print_verify_block() {', start)
print(source[start:end])
PY
)

_run_filter_active() { return 0; }
BLUE=''; NC=''
CAPTURED=""
warn() { CAPTURED="$CAPTURED$*
"; }
log() { :; }

# ---------------------------------------------------------------------------
# check_opencode_json_drift skips when the bridge reconcile failed.
# ---------------------------------------------------------------------------
CHAT_BRIDGE=roadie
SITE_PATH="$TMP/site"
SCRIPT_DIR="$SCRIPT_DIR"
mkdir -p "$SITE_PATH"
printf '{"model":"subrouter/openai-gpt-5.6-terra"}\n' > "$SITE_PATH/opencode.json"

BRIDGE_RECONCILE_FAILED=true
check_opencode_json_drift
case "$CAPTURED" in
  *"model-route rewrite and plugin retirement did not apply"*) : ;;
  *) echo "FAIL: bridge failure did not skip the opencode.json phase" >&2; exit 1 ;;
esac
case "$CAPTURED" in
  *"Do not restart the bridge; re-run the upgrade"*) : ;;
  *) echo "FAIL: skip message did not tell the operator not to restart" >&2; exit 1 ;;
esac
[ "$(cat "$SITE_PATH/opencode.json")" = '{"model":"subrouter/openai-gpt-5.6-terra"}' ] || {
  echo "FAIL: the skipped phase rewrote opencode.json anyway" >&2
  exit 1
}

# The gate is bridge-agnostic (records are bridges.<name>) and silent when
# the bridge reconcile succeeded. No opencode.json on disk means the phase
# returns before any repair dependency, so the success path needs no stubs.
CAPTURED=""
BRIDGE_RECONCILE_FAILED=false
SITE_PATH="$TMP/empty"
mkdir -p "$SITE_PATH"
check_opencode_json_drift
case "$CAPTURED" in
  *"model-route rewrite"*) echo "FAIL: gate fired on a successful bridge reconcile" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# _print_bridge_restart_hint withholds the restart command on bridge failure.
# ---------------------------------------------------------------------------
bridge_display_name() { printf 'roadie\n'; }

CAPTURED=""
BRIDGE_RECONCILE_FAILED=true
_print_bridge_restart_hint
case "$CAPTURED" in
  *"Do NOT restart roadie"*) : ;;
  *) echo "FAIL: failed bridge reconcile did not withhold the restart hint" >&2; exit 1 ;;
esac
case "$CAPTURED" in
  *"Re-run the upgrade once the failure is fixed, then restart."*) : ;;
  *) echo "FAIL: failed bridge reconcile did not give the re-run instruction" >&2; exit 1 ;;
esac
case "$CAPTURED" in
  *'systemctl'*|*'launchctl'*|*'"when ready"'*) echo "FAIL: restart command was printed despite the bridge failure" >&2; exit 1 ;;
esac

# The normal hint is untouched when the bridge reconcile succeeded.
CAPTURED=""
BRIDGE_RECONCILE_FAILED=false
_resolve_bridge_env() { printf 'vps\n'; }
bridge_restart_cmd() { printf 'sudo systemctl restart roadie.service\n'; }
_print_bridge_restart_hint
case "$CAPTURED" in
  *"Restart roadie when ready"*) : ;;
  *) echo "FAIL: successful bridge reconcile lost its restart hint" >&2; exit 1 ;;
esac

echo "PASS: tests/bridge-failure-gates-dependent-steps.sh"
