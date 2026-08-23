#!/bin/bash
# Managed VPS systems-capability profile and its fixed DMC inspection boundary.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

source lib/common.sh
wp_run_as_service_user() { return 0; }
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
SYSTEMS_CAPABILITIES_SUDOERS_DIR="$TMP/sudoers"
mkdir -p "$SITE_PATH/wp-content" "$DM_WORKSPACE_DIR/repo"

echo "systems capability policy is exact and bounded"
[ "$(systems_capabilities_journald_content)" = $'[Journal]\nSystemMaxUse=1G' ] && ok "journald cap is 1G" || fail "journald cap changed"
policy="$(systems_capabilities_logrotate_content)"
for directive in daily 'maxsize 100M' 'rotate 7' compress copytruncate 'su www-data www-data' 'create 0640 www-data www-data'; do
  case "$policy" in *"$directive"*) ;; *) fail "logrotate policy misses $directive" ;; esac
done
[ "$(systems_capabilities_sudoers_content)" = "opencode ALL=(root) NOPASSWD: $SYSTEMS_CAPABILITIES_LIB_DIR/dmc-process-inspect $(systems_capabilities_profile_file)" ] && ok "sudo rule binds the adapter to one profile" || fail "sudo rule is not exact"
SITE_PATH="$TMP/example.com"
case "$(basename "$(systems_capabilities_sudoers_file)")" in *.*) fail "sudoers filename contains an ignored dot" ;; *) ok "sudoers filename is include-safe" ;; esac
first_key="$(systems_capabilities_profile_key)"
SITE_PATH="$TMP/other/example.com"
mkdir -p "$SITE_PATH"
[ "$first_key" != "$(systems_capabilities_profile_key)" ] && ok "same-basename sites have collision-resistant keys" || fail "site profile keys collide"
SITE_PATH="$TMP/site"
case "$(systems_capabilities_profile_content)" in *'"invocation":"printf candidate-path | sudo -n '* ) ok "discovery records DMC's fixed stdin sudo contract" ;; *) fail "DMC invocation contract missing" ;; esac

echo "adapter rejects ambient paths and reports only configured workspace processes"
printf '{"workspace_roots":["%s"]}\n' "$DM_WORKSPACE_DIR" > "$TMP/profile.json"
if [ -d /proc ] && [ "$(id -u)" -ne 0 ]; then
  (cd "$DM_WORKSPACE_DIR/repo" && sleep 20) & sleeper=$!
  trap 'kill "$sleeper" 2>/dev/null || true; rm -rf "$TMP"' EXIT
  adapter_status=0
  out="$(printf '%s\n' "$DM_WORKSPACE_DIR/repo" | python3 scripts/dmc-process-inspect.py "$TMP/profile.json")" || adapter_status=$?
  if [ "$adapter_status" -eq 0 ]; then
    case "$out" in *'"status": "available"'* ) ;; *) fail "adapter did not return DMC's available status" ;; esac
    case "$out" in *"\"pid\": $sleeper"*|*"\"pid\":$sleeper"*) ok "configured workspace process is visible" ;; *) fail "adapter did not report workspace process" ;; esac
    case "$out" in *'"path": "'"$DM_WORKSPACE_DIR/repo"'"'* ) ok "adapter returns candidate-scoped process paths" ;; *) fail "adapter process evidence does not match DMC contract" ;; esac
  elif [ "$adapter_status" -eq 3 ]; then
    case "$out" in *'"status": "unavailable"'*'"error": "process inspection was incomplete"'*'"unreadable_count": '* ) ok "unreadable proc descriptors return bounded unavailable evidence" ;; *) fail "adapter did not bound incomplete process evidence" ;; esac
  else
    fail "adapter escaped its process-inspection contract"
  fi
else
  ok "live adapter evidence is exercised by the root VPS acceptance test"
fi
if printf '%s\n' "$TMP/outside" | python3 scripts/dmc-process-inspect.py "$TMP/profile.json" >/dev/null 2>&1; then
  fail "adapter accepted a path outside configured roots"
else
  ok "outside path is rejected"
fi
if python3 scripts/dmc-process-inspect.py "$TMP/profile.json" --path "$DM_WORKSPACE_DIR/repo" >/dev/null 2>&1; then
  fail "adapter accepted argv"
else
  ok "adapter rejects arbitrary command-style argv"
fi

echo "non-root repair is explicit and dry-run does not write"
repair="$(systems_capabilities_report_root_repair)"
case "$repair" in *root_repair_required*'--systems-capabilities managed-vps'*) ok "root repair is actionable" ;; *) fail "root repair contract missing" ;; esac
systems_capabilities_apply > "$TMP/dry-run.out"
[ ! -e "$SYSTEMS_CAPABILITIES_JOURNALD_FILE" ] && ok "dry-run leaves host policy untouched" || fail "dry-run wrote policy"

if [ "$failures" -eq 0 ]; then
  echo "systems-capabilities: all assertions passed"
else
  exit 1
fi
