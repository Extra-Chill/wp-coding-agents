#!/bin/bash
# Managed VPS policy must not expose an unowned process-inspection contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

source lib/common.sh
source lib/systems-capabilities.sh
SITE_PATH="$TMP/site"
DM_WORKSPACE_DIR="$TMP/workspace"
SERVICE_USER=opencode
DRY_RUN=true
LOCAL_MODE=false
SYSTEMS_CAPABILITIES_PROFILE=managed-vps
SYSTEMS_CAPABILITIES_PROFILE_ROOT="$TMP/profiles"
SYSTEMS_CAPABILITIES_LIB_DIR="$TMP/lib"
SYSTEMS_CAPABILITIES_BIN_DIR="$TMP/bin"
SYSTEMS_CAPABILITIES_JOURNALD_FILE="$TMP/journald.conf"
SYSTEMS_CAPABILITIES_LOGROTATE_DIR="$TMP/logrotate"
SYSTEMS_CAPABILITIES_SYSTEMD_DIR="$TMP/systemd"
SYSTEMS_CAPABILITIES_SUDOERS_DIR="$TMP/sudoers"
mkdir -p "$SITE_PATH/wp-content" "$DM_WORKSPACE_DIR/repo"

echo "systems capability policy remains exact and bounded"
[ "$(systems_capabilities_journald_content)" = $'[Journal]\nSystemMaxUse=1G' ] && ok "journald cap is 1G" || fail "journald cap changed"
policy="$(systems_capabilities_logrotate_content)"
for directive in daily 'maxsize 100M' 'rotate 7' compress copytruncate 'su www-data www-data' 'create 0640 www-data www-data'; do
  case "$policy" in *"$directive"*) ;; *) fail "logrotate policy misses $directive" ;; esac
done
timer="$(systems_capabilities_logrotate_timer_content)"
for directive in 'OnCalendar=' 'OnCalendar=*:0/5' 'AccuracySec=1min' 'RandomizedDelaySec=0' 'Persistent=true'; do
  case "$timer" in *"$directive"*) ;; *) fail "logrotate timer misses $directive" ;; esac
done
[ "$(systems_capabilities_logrotate_timer_file)" = "$SYSTEMS_CAPABILITIES_SYSTEMD_DIR/logrotate.timer.d/wp-coding-agents.conf" ] && ok "logrotate cadence extends the owner timer" || fail "logrotate timer path is not fixed"
case "$(systems_capabilities_profile_content)" in *'process_inspection'*) fail "retired inspection contract remains discoverable" ;; *) ok "profile omits the unowned inspection contract" ;; esac
case "$(systems_capabilities_profile_content)" in *'"timer":"logrotate.timer"'*'"schedule":"*:0/5"'*) ok "logrotate timer contract remains discoverable" ;; *) fail "logrotate timer contract missing" ;; esac

echo "retired process probes are removed"
mkdir -p "$SYSTEMS_CAPABILITIES_LIB_DIR" "$SYSTEMS_CAPABILITIES_SUDOERS_DIR"
touch "$SYSTEMS_CAPABILITIES_LIB_DIR/dmc-process-inspect" "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" "$(systems_capabilities_retired_sudoers_file)"
DRY_RUN=false
systems_capabilities_cleanup_retired_process_probe
[ ! -e "$SYSTEMS_CAPABILITIES_LIB_DIR/dmc-process-inspect" ] && [ ! -e "$SYSTEMS_CAPABILITIES_LIB_DIR/process-inspect" ] && [ ! -e "$(systems_capabilities_retired_sudoers_file)" ] && ok "retired process probes are removed" || fail "retired process probe cleanup failed"

echo "non-root repair is explicit and dry-run does not write"
DRY_RUN=true
repair="$(systems_capabilities_report_root_repair)"
case "$repair" in *root_repair_required*'--systems-capabilities managed-vps'*) ok "root repair is actionable" ;; *) fail "root repair contract missing" ;; esac
systems_capabilities_apply > "$TMP/dry-run.out"
[ ! -e "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" ] && ok "dry-run leaves host policy untouched" || fail "dry-run wrote policy"

[ "$failures" -eq 0 ] && echo "systems-capabilities: all assertions passed" || exit 1
