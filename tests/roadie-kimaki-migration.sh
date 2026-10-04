#!/bin/bash
# tests/roadie-kimaki-migration.sh — a Kimaki install migrates to Roadie in place.
#
# The migration stops Kimaki, takes an SQLite online backup of its session
# database (WAL mode, so a plain copy could catch it mid-write), copies the
# remaining state, carries the bot token / lock port / agent slug, and disables
# Kimaki while keeping its unit and data dir untouched as the rollback. A
# failed backup must restart Kimaki rather than leave the host without a bridge.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

command -v sqlite3 >/dev/null 2>&1 || { echo "FAIL: sqlite3 is required (the migration itself uses it)"; exit 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

log() { :; }
warn() { :; }
systemctl() { printf '%s\n' "$*" >> "$TMP/systemctl.log"; }
# The account move has its own suite (tests/roadie-accounts.sh); here it is
# recorded in the same log so its ordering against stop/disable is checked.
ACCOUNTS_RESULT=0
_roadie_accounts() { printf 'accounts %s\n' "$1" >> "$TMP/systemctl.log"; echo "anthropic: 3 account(s), active #2"; return "$ACCOUNTS_RESULT"; }
DRY_RUN=false
UPDATED_ITEMS=()
LOCAL_MODE=false
SERVICE_USER=""
WP_CODING_AGENTS_TEST_EUID=1000
SYSTEMD_UNIT_DIR="$TMP/systemd"
SERVICE_HOME="$TMP/home"
KIMAKI_DATA="$SERVICE_HOME/.kimaki"
mkdir -p "$SYSTEMD_UNIT_DIR" "$KIMAKI_DATA/attachments" "$KIMAKI_DATA/projects/demo"

cat > "$SYSTEMD_UNIT_DIR/kimaki.service" <<EOF
[Service]
User=opencode
Environment=HOME=$SERVICE_HOME
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA
Environment=KIMAKI_BOT_TOKEN=bot-token-from-unit
Environment=DATAMACHINE_AGENT_SLUG=extra-chill-bot
ExecStart=/usr/bin/kimaki --data-dir $KIMAKI_DATA --lock-port 31337 --auto-restart
EOF
UNIT_BEFORE="$(cksum < "$SYSTEMD_UNIT_DIR/kimaki.service")"

# A WAL-mode session database, as Kimaki keeps it.
DB="$KIMAKI_DATA/discord-sessions.db"
sqlite3 "$DB" "PRAGMA journal_mode=WAL; CREATE TABLE thread_sessions(thread_id TEXT PRIMARY KEY, session_id TEXT);" >/dev/null
for i in 1 2 3; do sqlite3 "$DB" "INSERT INTO thread_sessions VALUES ('t$i','s$i');"; done
printf 'png' > "$KIMAKI_DATA/attachments/a.png"
printf 'x' > "$KIMAKI_DATA/projects/demo/state"
DATA_BEFORE="$(cd "$KIMAKI_DATA" && find . -type f -exec cksum {} + | sort)"

echo "==> VPS migration"
ROADIE_UNIT=roadie.service
ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
unset ROADIE_BOT_TOKEN ROADIE_LOCK_PORT AGENT_SLUG KIMAKI_UNIT
roadie_migrate_from_kimaki

[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" 'SELECT count(*) FROM thread_sessions;')" = 3 ]
check $? "all rows reach the Roadie database"
[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" 'PRAGMA integrity_check;')" = ok ]; check $? "migrated database passes integrity_check"
[ -f "$ROADIE_DATA_DIR/attachments/a.png" ] && [ -f "$ROADIE_DATA_DIR/projects/demo/state" ]; check $? "attachments and projects copied"
[ "${ROADIE_BOT_TOKEN:-}" = bot-token-from-unit ]; check $? "bot token carried from the Kimaki unit"
[ "${ROADIE_LOCK_PORT:-}" = 31337 ]; check $? "lock port carried (ExecStart --lock-port form)"
[ "${AGENT_SLUG:-}" = extra-chill-bot ]; check $? "agent slug carried"
grep -qx "stop kimaki.service" "$TMP/systemctl.log"; check $? "Kimaki stopped before the backup"
grep -qx "disable kimaki.service" "$TMP/systemctl.log"; check $? "Kimaki disabled after the migration"
[ "$(grep -n 'stop kimaki.service' "$TMP/systemctl.log" | cut -d: -f1)" -lt "$(grep -n 'disable kimaki.service' "$TMP/systemctl.log" | cut -d: -f1)" ]; check $? "stop precedes disable"
[ "$(cksum < "$SYSTEMD_UNIT_DIR/kimaki.service")" = "$UNIT_BEFORE" ]; check $? "Kimaki unit file kept unchanged (rollback)"
[ "$(cd "$KIMAKI_DATA" && find . -type f -exec cksum {} + | sort | grep -v 'discord-sessions.db-\(wal\|shm\)')" = "$(printf '%s\n' "$DATA_BEFORE" | grep -v 'discord-sessions.db-\(wal\|shm\)')" ]
check $? "Kimaki data dir kept unchanged (rollback)"
printf '%s\n' "${UPDATED_ITEMS[@]}" | grep -q "kept as rollback"; check $? "summary reports the kept rollback"
line() { grep -nx "$1" "$TMP/systemctl.log" | head -1 | cut -d: -f1; }
[ -n "$(line 'accounts import')" ] && [ "$(line 'stop kimaki.service')" -lt "$(line 'accounts import')" ] && [ "$(line 'accounts import')" -lt "$(line 'disable kimaki.service')" ]
check $? "accounts move into subrouter while Kimaki is stopped, before it is disabled"
printf '%s\n' "${UPDATED_ITEMS[@]}" | grep -q "accounts.mjs export"; check $? "summary gives the account rollback command"

echo "==> re-run never overwrites Roadie data"
sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "INSERT INTO thread_sessions VALUES ('roadie-only','x');"
: > "$TMP/systemctl.log"
roadie_migrate_from_kimaki
[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "SELECT count(*) FROM thread_sessions WHERE thread_id='roadie-only';")" = 1 ]; check $? "existing Roadie database kept"
[ ! -s "$TMP/systemctl.log" ]; check $? "no service actions on re-run"

echo "==> a failed backup restarts Kimaki"
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
sqlite3() { [ "${1:-}" = -readonly ] && return 1; command sqlite3 "$@"; }
( roadie_migrate_from_kimaki ) >/dev/null 2>&1
rc=$?
unset -f sqlite3
[ "$rc" -ne 0 ]; check $? "migration fails"
grep -qx "start kimaki.service" "$TMP/systemctl.log"; check $? "Kimaki started again"
! grep -qx "disable kimaki.service" "$TMP/systemctl.log"; check $? "Kimaki not disabled"
[ ! -f "$ROADIE_DATA_DIR/discord-sessions.db" ]; check $? "no partial Roadie database left behind"

echo "==> a failed account move restarts Kimaki"
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
ACCOUNTS_RESULT=1
( roadie_migrate_from_kimaki ) >/dev/null 2>&1
rc=$?
ACCOUNTS_RESULT=0
[ "$rc" -ne 0 ]; check $? "migration fails"
grep -qx "start kimaki.service" "$TMP/systemctl.log"; check $? "Kimaki started again"
! grep -qx "disable kimaki.service" "$TMP/systemctl.log"; check $? "Kimaki not disabled"
[ ! -f "$ROADIE_DATA_DIR/discord-sessions.db" ]; check $? "no Roadie database left behind, so the next run retries"

echo "==> no Kimaki unit, nothing to do"
mv "$SYSTEMD_UNIT_DIR/kimaki.service" "$TMP/kimaki.service.away"
: > "$TMP/systemctl.log"
roadie_migrate_from_kimaki
[ ! -s "$TMP/systemctl.log" ] && [ ! -e "$ROADIE_DATA_DIR/discord-sessions.db" ]; check $? "fresh install is untouched"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-kimaki-migration.sh ($PASS assertions)"
