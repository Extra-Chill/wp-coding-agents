#!/bin/bash
# tests/roadie-remote-pool.sh — a bot bills through a remote credential pool
# host (Extra-Chill/roadie#226) once it has both the host URL and its client
# key; without the key it keeps its local pool and reports the gap.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

log() { :; }
warn() { printf 'WARN: %s\n' "$*" >> "$TMP/warn.log"; }
error() { printf 'ERROR: %s\n' "$*" >> "$TMP/warn.log"; return 1; }
systemctl() { :; }

POOL_URL="http://100.101.19.112:47120"
SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site"

unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT AGENT_SLUG ROADIE_POOL_URL ROADIE_POOL_KEY
initialize_roadie_overrides
ROADIE_UNIT=roadie.service
SITE_PATH="$TMP/site"
SERVICE_USER="$(id -un)"
SERVICE_HOME="$TMP/home"
SERVICE_USER_FORCED=true
LOCAL_MODE=false
ROADIE_DATA_DIR="$TMP/home/.roadie"
ROADIE_SYSTEM_PREFIX="$TMP/roadie-prefix"
ROADIE_SECRETS_ROOT="$TMP/secrets"
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
PENDING_ITEMS=()
WP_CMD=wp
WP_CLI_TRANSPORT=(wp)
IS_STUDIO=false
WP_CODING_AGENTS_TEST_EUID=0
# Pi selection is covered by roadie-pi-backend.sh; keep it out of the way.
ROADIE_PI_VERIFIED=none
_roadie_select_pi() { ROADIE_PI_BIN=/fixture/pi; }
ROADIE_BIN="$(roadie_bin)"
UNIT="$SYSTEMD_UNIT_DIR/roadie.service"
KEY_FILE="$TMP/secrets/roadie/pool-key"
ADMIN_KEY_FILE="$TMP/secrets/roadie/pool-admin-key"

write_unit() {
  cat > "$UNIT" <<EOF
[Service]
User=$SERVICE_USER
WorkingDirectory=$TMP/site
Environment=HOME=$TMP/home
Environment=PATH=/usr/bin:/bin
Environment=ROADIE_DATA_DIR=$TMP/home/.roadie
Environment=DATAMACHINE_SITE_PATH=$TMP/site
Environment=HOST_CUSTOM=preserved
$1
ExecStart=/usr/bin/roadie --data-dir $TMP/home/.roadie --auto-restart
EOF
}
count() { grep -cFx "Environment=$1" "$UNIT"; }
reset() { : > "$TMP/warn.log"; PENDING_ITEMS=(); UPDATED_ITEMS=(); unset ROADIE_POOL_KEY_REPORTED ROADIE_POOL_KEY ROADIE_POOL_ADMIN_KEY; }

echo "==> a URL without the client key keeps the local pool and reports the gap"
reset
write_unit ""
ROADIE_POOL_URL="$POOL_URL" ROADIE_POOL_URL_EXPLICIT=true
bridge_update_systemd >/dev/null 2>&1
! grep -q '^Environment=ROADIE_POOL_' "$UNIT"; check $? "no pool keys rendered without the key"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -qF "Roadie pool client key"; check $? "missing key is a pending item"
[ "$(grep -c 'pool-key is missing' "$TMP/warn.log")" -eq 1 ]; check $? "reported once"

echo "==> ROADIE_POOL_KEY is stored as a 0600 secret and both keys render once"
reset
export ROADIE_POOL_KEY="rpk_test_key"
_roadie_install_secrets >/dev/null 2>&1
unset ROADIE_POOL_KEY
[ "$(cat "$KEY_FILE")" = rpk_test_key ]; check $? "key written to <secrets>/pool-key"
[ "$(stat -c %a "$KEY_FILE" 2>/dev/null || stat -f %Lp "$KEY_FILE")" = 600 ]; check $? "key file is 0600"
bridge_update_systemd >/dev/null 2>&1
[ "$(count "ROADIE_POOL_URL=$POOL_URL")" -eq 1 ]; check $? "ROADIE_POOL_URL rendered once"
[ "$(count "ROADIE_POOL_KEY_FILE=$KEY_FILE")" -eq 1 ]; check $? "ROADIE_POOL_KEY_FILE rendered once"
! grep -q "rpk_test_key" "$UNIT"; check $? "the key itself never enters the unit"
[ "$(count HOST_CUSTOM=preserved)" -eq 1 ]; check $? "operator env survives"

echo "==> no admin key: ROADIE_POOL_ADMIN_KEY_FILE is not rendered"
! grep -q '^Environment=ROADIE_POOL_ADMIN_KEY_FILE' "$UNIT"; check $? "no admin key file without the key"

echo "==> ROADIE_POOL_ADMIN_KEY is stored as a 0600 secret and rendered once"
reset
export ROADIE_POOL_ADMIN_KEY="rpc_admin_test_key"
_roadie_install_secrets >/dev/null 2>&1
unset ROADIE_POOL_ADMIN_KEY
[ "$(cat "$ADMIN_KEY_FILE")" = rpc_admin_test_key ]; check $? "admin key written to <secrets>/pool-admin-key"
[ "$(stat -c %a "$ADMIN_KEY_FILE" 2>/dev/null || stat -f %Lp "$ADMIN_KEY_FILE")" = 600 ]; check $? "admin key file is 0600"
bridge_update_systemd >/dev/null 2>&1
[ "$(count "ROADIE_POOL_ADMIN_KEY_FILE=$ADMIN_KEY_FILE")" -eq 1 ]; check $? "ROADIE_POOL_ADMIN_KEY_FILE rendered once"
! grep -q "rpc_admin_test_key" "$UNIT"; check $? "the admin key itself never enters the unit"

echo "==> a later upgrade adopts the URL from the installed unit"
reset
unset ROADIE_POOL_URL ROADIE_UNIT
initialize_roadie_overrides
ROADIE_DATA_DIR="$TMP/home/.roadie" ROADIE_DATA_DIR_EXPLICIT=true
_roadie_resolve_instance
[ "$ROADIE_POOL_URL" = "$POOL_URL" ]; check $? "instance resolution adopts ROADIE_POOL_URL from the unit"
bridge_update_systemd >/dev/null 2>&1
[ "$(count "ROADIE_POOL_URL=$POOL_URL")" -eq 1 ]; check $? "URL kept without the flag"
cp "$UNIT" "$TMP/converged"
bridge_update_systemd >/dev/null 2>&1
cmp -s "$UNIT" "$TMP/converged"; check $? "re-runs are byte-identical"

echo "==> --roadie-pool-url local returns to the bot's own pool"
reset
ROADIE_POOL_URL=local ROADIE_POOL_URL_EXPLICIT=true
bridge_update_systemd >/dev/null 2>&1
! grep -q '^Environment=ROADIE_POOL_' "$UNIT"; check $? "pool keys removed (admin key file included)"

echo "==> an invalid URL is refused"
reset
ROADIE_POOL_URL="ftp://nope" ROADIE_POOL_URL_EXPLICIT=true
( _roadie_remote_pool_url ) >/dev/null 2>&1
grep -q "Invalid --roadie-pool-url" "$TMP/warn.log"; check $? "invalid URL reported"

echo "==> launchd plist and manual command carry the remote pool"
reset
ROADIE_POOL_URL="$POOL_URL" ROADIE_POOL_URL_EXPLICIT=true
PLIST="$(LOCAL_MODE=false ROADIE_BIN=/usr/bin/roadie bridge_render_launchd com.wp.roadie 2>/dev/null)"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_POOL_URL</key>' | grep -qF "<string>$POOL_URL</string>"; check $? "launchd ROADIE_POOL_URL"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_POOL_KEY_FILE</key>' | grep -qF "<string>$KEY_FILE</string>"; check $? "launchd ROADIE_POOL_KEY_FILE"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_POOL_ADMIN_KEY_FILE</key>' | grep -qF "<string>$ADMIN_KEY_FILE</string>"; check $? "launchd ROADIE_POOL_ADMIN_KEY_FILE"
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$PLIST" > "$TMP/roadie.plist"
  plutil -lint "$TMP/roadie.plist" >/dev/null; check $? "launchd plist stays valid"
fi
_roadie_manual_command | grep -qF "ROADIE_POOL_URL='$POOL_URL' ROADIE_POOL_KEY_FILE='$KEY_FILE' ROADIE_POOL_ADMIN_KEY_FILE='$ADMIN_KEY_FILE'"; check $? "manual command carries the pool keys"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: tests/roadie-remote-pool.sh ($FAIL failed, $PASS passed)"
  exit 1
fi
echo "PASS: tests/roadie-remote-pool.sh ($PASS assertions)"
