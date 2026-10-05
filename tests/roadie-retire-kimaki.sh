#!/bin/bash
# tests/roadie-retire-kimaki.sh — Kimaki's grants and unit go once Roadie is
# healthy (#667); the Kimaki data dir and unrelated grants never do.
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
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

log() { :; }
warn() { printf '%s\n' "$*" >> "$TMP/warn.log"; }
DRY_RUN=false
UPDATED_ITEMS=()
LOCAL_MODE=false
ROADIE_UNIT=roadie.service
ROADIE_LOCK_PORT=29988
export WP_CODING_AGENTS_TEST_EUID=0
SYSTEMD_UNIT_DIR="$TMP/systemd"
KIMAKI_RETIRE_SUDOERS_DIR="$TMP/sudoers.d"
KIMAKI_DISPATCH_WRAPPER_DIR="$TMP/bin"
KIMAKI_DISPATCH_TARGET_DIR="$TMP/lib"
KIMAKI_DATA="$TMP/home/.kimaki"

HEALTHY=1
systemctl() {
  printf '%s\n' "$*" >> "$TMP/systemctl.log"
  [ "$1" = is-active ] && { [ "$HEALTHY" = 1 ]; return; }
  return 0
}
curl() { [ "$HEALTHY" = 1 ] && echo '{"status":"ok","discordReady":true}'; }

setup_host() {
  rm -rf "$SYSTEMD_UNIT_DIR" "$KIMAKI_RETIRE_SUDOERS_DIR" "$TMP/bin" "$TMP/lib" "$TMP/warn.log" "$TMP/systemctl.log"
  mkdir -p "$SYSTEMD_UNIT_DIR" "$KIMAKI_RETIRE_SUDOERS_DIR" "$TMP/bin" "$TMP/lib" "$KIMAKI_DATA"
  printf '[Service]\nExecStart=/usr/bin/kimaki\n' > "$SYSTEMD_UNIT_DIR/kimaki.service"
  printf '[Service]\nExecStart=/usr/bin/roadie\n' > "$SYSTEMD_UNIT_DIR/roadie.service"
  echo 'opencode ALL=(opencode) NOPASSWD: /usr/local/lib/wp-coding-agents/kimaki-dispatch-target *' > "$KIMAKI_RETIRE_SUDOERS_DIR/wp-coding-agents-kimaki-dispatch"
  echo 'opencode ALL=(root) NOPASSWD: /usr/bin/systemctl restart kimaki.service' > "$KIMAKI_RETIRE_SUDOERS_DIR/wp-coding-agents-kimaki-restart"
  printf '# hand-added\nopencode ALL=(root) NOPASSWD: /usr/bin/kimaki upgrade, /usr/bin/kimaki upgrade --skip-restart\n' > "$KIMAKI_RETIRE_SUDOERS_DIR/kimaki-upgrade"
  echo 'opencode ALL=(root) NOPASSWD: /usr/local/sbin/homeboy-upgrade *' > "$KIMAKI_RETIRE_SUDOERS_DIR/homeboy-upgrade"
  printf 'opencode ALL=(root) NOPASSWD: /usr/bin/kimaki upgrade\nopencode ALL=(root) NOPASSWD: /usr/bin/true\n' > "$KIMAKI_RETIRE_SUDOERS_DIR/mixed"
  touch "$TMP/bin/wp-coding-agents-kimaki-dispatch" "$TMP/lib/kimaki-dispatch-target" "$KIMAKI_DATA/discord-sessions.db"
}

echo "==> unhealthy Roadie: keep the rollback"
setup_host
HEALTHY=0
roadie_retire_kimaki_artifacts
[ -f "$SYSTEMD_UNIT_DIR/kimaki.service" ] && [ -f "$KIMAKI_RETIRE_SUDOERS_DIR/wp-coding-agents-kimaki-restart" ]
check $? "nothing removed while Roadie is not healthy"

echo "==> healthy Roadie: retire Kimaki"
HEALTHY=1
UPDATED_ITEMS=()
roadie_retire_kimaki_artifacts
[ ! -e "$SYSTEMD_UNIT_DIR/kimaki.service" ]; check $? "kimaki.service removed"
grep -qx "stop kimaki.service" "$TMP/systemctl.log" && grep -qx "disable kimaki.service" "$TMP/systemctl.log"
check $? "Kimaki stopped and disabled before removal"
for f in wp-coding-agents-kimaki-dispatch wp-coding-agents-kimaki-restart kimaki-upgrade; do
  [ ! -e "$KIMAKI_RETIRE_SUDOERS_DIR/$f" ]; check $? "grant $f removed"
done
[ ! -e "$TMP/bin/wp-coding-agents-kimaki-dispatch" ] && [ ! -e "$TMP/lib/kimaki-dispatch-target" ]
check $? "dispatch wrapper and target removed"
[ -f "$KIMAKI_RETIRE_SUDOERS_DIR/homeboy-upgrade" ]; check $? "unrelated grant kept"
[ -f "$KIMAKI_RETIRE_SUDOERS_DIR/mixed" ]; check $? "mixed grant kept"
grep -q "mixed mixes Kimaki rules" "$TMP/warn.log"; check $? "operator warned about the mixed grant"
[ -f "$KIMAKI_DATA/discord-sessions.db" ]; check $? "Kimaki data dir untouched"
[ -f "$SYSTEMD_UNIT_DIR/roadie.service" ]; check $? "roadie.service untouched"
printf '%s\n' "${UPDATED_ITEMS[@]}" | grep -q "data dir kept"; check $? "summary reports it"

echo "==> idempotent; scope"
: > "$TMP/systemctl.log"; UPDATED_ITEMS=()
roadie_retire_kimaki_artifacts
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] && ! grep -q kimaki "$TMP/systemctl.log"; check $? "re-run is a no-op"
setup_host
( WP_CODING_AGENTS_TEST_EUID=1000; roadie_retire_kimaki_artifacts ); [ -f "$SYSTEMD_UNIT_DIR/kimaki.service" ]; check $? "non-root run: nothing"
( LOCAL_MODE=true; roadie_retire_kimaki_artifacts ); [ -f "$SYSTEMD_UNIT_DIR/kimaki.service" ]; check $? "local install: nothing"
( DRY_RUN=true; roadie_retire_kimaki_artifacts ) | grep -q "Would remove Kimaki artifact"; check $? "dry run reports"
[ -f "$SYSTEMD_UNIT_DIR/kimaki.service" ]; check $? "dry run removes nothing"

echo
if [ "$FAIL" -gt 0 ]; then echo "FAIL: $FAIL assertion(s)"; exit 1; fi
echo "PASS: tests/roadie-retire-kimaki.sh ($PASS assertions)"
