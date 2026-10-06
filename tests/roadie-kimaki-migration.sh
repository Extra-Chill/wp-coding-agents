#!/bin/bash
# tests/roadie-kimaki-migration.sh — a Kimaki install migrates to Roadie in place.
#
# The migration stops Kimaki, takes an SQLite online backup of its session
# database (WAL mode, so a plain copy could catch it mid-write), copies the
# remaining state, carries the bot token / lock port / agent slug, and disables
# Kimaki while keeping its unit and data dir untouched as the rollback. A
# failed backup must restart Kimaki rather than leave the host without a bridge.
#
# Two gates keep that guarantee end to end (#692): a node too old for the
# pinned Roadie release refuses the migration before Kimaki is touched (dry
# run reports the refusal instead of "Would stop"), and once a migration
# actually happened, install starts the unit and waits for a healthy Discord
# gateway — an unhealthy Roadie is stopped and disabled while Kimaki is
# re-enabled and restarted, and the run fails instead of exiting 0.
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
# The Node preflight resolves the service's node through `command -v node`
# when no rendered PATH entry exists, so a function stub covers it the same
# way systemctl is above. NODE_MAJOR=24 lets the main migration proceed;
# the preflight sections below flip it to model an old host.
NODE_MAJOR=24
node() { if [ "${1:-}" = --version ]; then printf 'v%s.0.0\n' "$NODE_MAJOR"; fi; return 0; }
# One sqlite3 wrapper for the whole file (defined before first use): the
# failed-backup section flips SQLITE3_READONLY_FAILS to model a database that
# refuses the online backup, rather than redefining the function mid-file.
SQLITE3_READONLY_FAILS=0
sqlite3() { if [ "$SQLITE3_READONLY_FAILS" = 1 ] && [ "${1:-}" = -readonly ]; then return 1; fi; command sqlite3 "$@"; }
# The account move has its own suite (tests/roadie-accounts.sh); here it is
# recorded in the same log so its ordering against stop/disable is checked.
ACCOUNTS_RESULT=0
_roadie_accounts() { printf 'accounts %s\n' "$1" >> "$TMP/systemctl.log"; printf '%s\n' "${ROADIE_SUBROUTER_PRESETS_JSON:-}" > "$TMP/presets.json"; echo "anthropic: 3 account(s), active #2"; return "$ACCOUNTS_RESULT"; }
DRY_RUN=false
UPDATED_ITEMS=()
PENDING_ITEMS=()
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

# A WAL-mode session database, as Kimaki keeps it. The schema here is the
# Kimaki-era shape: channel_directories without guild_id, thread_worktrees as
# the legacy working-directory table, and error text columns that must never
# be rewritten by the path relocation.
DB="$KIMAKI_DATA/discord-sessions.db"
sqlite3 "$DB" "PRAGMA journal_mode=WAL; CREATE TABLE thread_sessions(thread_id TEXT PRIMARY KEY, session_id TEXT);" >/dev/null
for i in 1 2 3; do sqlite3 "$DB" "INSERT INTO thread_sessions VALUES ('t$i','s$i');"; done
sqlite3 "$DB" "CREATE TABLE session_models(session_id TEXT PRIMARY KEY, model_id TEXT NOT NULL, variant TEXT);
  INSERT INTO session_models VALUES ('s1','anthropic/claude-opus-5-5','max'),('s2','openai/gpt-6.1-sol',NULL),('s3','zai-coding-plan/glm-5.2',NULL);"
sqlite3 "$DB" "CREATE TABLE channel_directories(channel_id TEXT PRIMARY KEY, directory TEXT NOT NULL, channel_type TEXT NOT NULL);
  INSERT INTO channel_directories VALUES
    ('c1','$KIMAKI_DATA/projects/demo','text'),
    ('c2','$TMP/site-external','text'),
    ('c3','$KIMAKI_DATA/projects-demo','text'),
    ('c4','$KIMAKI_DATA/projects/demo/','text');"
sqlite3 "$DB" "CREATE TABLE thread_worktrees(thread_id TEXT PRIMARY KEY, worktree_name TEXT, worktree_directory TEXT, project_directory TEXT);
  INSERT INTO thread_worktrees VALUES ('t1','b','$KIMAKI_DATA/projects/demo/.worktrees/b','$KIMAKI_DATA/projects/demo');"
sqlite3 "$DB" "CREATE TABLE scheduled_tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, next_run_at TEXT NOT NULL, payload_json TEXT NOT NULL, prompt_preview TEXT NOT NULL, project_directory TEXT, last_error TEXT);
  INSERT INTO scheduled_tasks (next_run_at,payload_json,prompt_preview,project_directory,last_error)
    VALUES ('2030-01-01','{}','weekly sweep','$KIMAKI_DATA/projects/demo','old failure at $KIMAKI_DATA/projects/demo/known');"
sqlite3 "$DB" "CREATE TABLE scheduled_task_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, scheduled_task_id INTEGER NOT NULL, status TEXT, project_directory TEXT, error TEXT);
  INSERT INTO scheduled_task_runs (scheduled_task_id,status,project_directory,error)
    VALUES (1,'failed','$KIMAKI_DATA/projects/demo','run died in $KIMAKI_DATA/projects/demo/sub');"
SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH" "$TMP/site-external"
printf '{"model":"anthropic/claude-opus-5-5","small_model":"anthropic/claude-sonnet-5-5","plugin":["x"]}\n' > "$SITE_PATH/opencode.json"
printf 'png' > "$KIMAKI_DATA/attachments/a.png"
printf 'x' > "$KIMAKI_DATA/projects/demo/state"
DATA_BEFORE="$(cd "$KIMAKI_DATA" && find . -type f -exec cksum {} + | sort)"

echo "==> VPS migration"
ROADIE_UNIT=roadie.service
ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
unset ROADIE_BOT_TOKEN ROADIE_LOCK_PORT AGENT_SLUG KIMAKI_UNIT KIMAKI_DATA_DIR
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
NEW_DB="$ROADIE_DATA_DIR/discord-sessions.db"
[ "$(sqlite3 "$NEW_DB" "SELECT model_id||'|'||ifnull(variant,'') FROM session_models ORDER BY session_id" | tr '\n' ' ')" = "subrouter/anthropic-claude-opus-5-5| subrouter/openai-gpt-6.1-sol| zai-coding-plan/glm-5.2| " ]
check $? "OAuth model choices routed through per-model presets; API-key model kept"
[ "$(sqlite3 "$DB" "SELECT model_id FROM session_models WHERE session_id='s1'")" = anthropic/claude-opus-5-5 ]; check $? "Kimaki database keeps its model choices (rollback)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d=={'anthropic-claude-opus-5-5':['anthropic/claude-opus-5-5'],'anthropic-claude-sonnet-5-5':['anthropic/claude-sonnet-5-5'],'openai-gpt-6.1-sol':['openai/gpt-6.1-sol']}, d" "$TMP/presets.json"
check $? "presets derived from stored choices and opencode.json, one model each"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert (d['model'],d['small_model'],d['plugin'])==('subrouter/anthropic-claude-opus-5-5','subrouter/anthropic-claude-sonnet-5-5',['x']), d" "$SITE_PATH/opencode.json"
check $? "opencode.json defaults routed through subrouter, other keys kept"
ls "$SITE_PATH"/opencode.json.before-subrouter-* >/dev/null 2>&1; check $? "opencode.json backed up"

# #660: the copy carries the database's operational directory bindings, so the
# migration must relocate exactly the references into the copied projects root
# and leave everything else verbatim.
[ "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c1'")" = "$ROADIE_DATA_DIR/projects/demo" ]
check $? "copied project's channel binding points at the Roadie copy"
[ "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c4'")" = "$ROADIE_DATA_DIR/projects/demo/" ]
check $? "trailing separator survives relocation"
[ "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c2'")" = "$TMP/site-external" ]
check $? "external project binding preserved"
[ "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c3'")" = "$KIMAKI_DATA/projects-demo" ]
check $? "sibling prefix is not relocated (component-safe mapping)"
[ "$(sqlite3 "$NEW_DB" "SELECT project_directory||'|'||worktree_directory FROM thread_worktrees")" = "$ROADIE_DATA_DIR/projects/demo|$ROADIE_DATA_DIR/projects/demo/.worktrees/b" ]
check $? "thread working-directory references relocated"
[ "$(sqlite3 "$NEW_DB" "SELECT project_directory FROM scheduled_tasks")" = "$ROADIE_DATA_DIR/projects/demo" ]
check $? "scheduled task project directory relocated"
[ "$(sqlite3 "$NEW_DB" "SELECT last_error FROM scheduled_tasks")" = "old failure at $KIMAKI_DATA/projects/demo/known" ]
check $? "historical error text preserved"
[ "$(sqlite3 "$NEW_DB" "SELECT project_directory FROM scheduled_task_runs")" = "$ROADIE_DATA_DIR/projects/demo" ]
check $? "scheduled task run directory relocated"
[ "$(sqlite3 "$NEW_DB" "SELECT error FROM scheduled_task_runs")" = "run died in $KIMAKI_DATA/projects/demo/sub" ]
check $? "run error text preserved"
[ "$(sqlite3 "$DB" "SELECT directory FROM channel_directories WHERE channel_id='c1'")" = "$KIMAKI_DATA/projects/demo" ]
check $? "Kimaki database keeps its own bindings (rollback)"

echo "==> copied projects stay reachable after the retired directory is removed"
rm -rf "$KIMAKI_DATA/projects/demo"
[ -f "$ROADIE_DATA_DIR/projects/demo/state" ] \
  && [ -d "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c1'")" ]
check $? "relocated binding resolves to the copied project without the original"

echo "==> re-run never overwrites Roadie data"
sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "INSERT INTO thread_sessions VALUES ('roadie-only','x');"
: > "$TMP/systemctl.log"
roadie_migrate_from_kimaki
[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "SELECT count(*) FROM thread_sessions WHERE thread_id='roadie-only';")" = 1 ]; check $? "existing Roadie database kept"
[ ! -s "$TMP/systemctl.log" ]; check $? "no service actions on re-run"
[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "SELECT count(*) FROM channel_directories WHERE directory = '$KIMAKI_DATA/projects/demo' OR directory = '$KIMAKI_DATA/projects/demo/'")" = 0 ]
check $? "re-run leaves relocated bindings alone (idempotent)"

echo "==> an existing Roadie copy with retired-path bindings converges on re-run"
# Simulate a copy migrated before the relocation existed: its bindings still
# point beneath the retired Kimaki projects root, whose demo project has
# already been removed above.
sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "INSERT INTO channel_directories VALUES
  ('c9','$KIMAKI_DATA/projects/demo','text'),
  ('c10','$KIMAKI_DATA/projects/never-copied','text');"
UPDATED_ITEMS_BEFORE="${#UPDATED_ITEMS[@]}"
roadie_migrate_from_kimaki
[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "SELECT directory FROM channel_directories WHERE channel_id='c9'")" = "$ROADIE_DATA_DIR/projects/demo" ]
check $? "stale binding whose project was copied is relocated in the existing copy"
[ "$(sqlite3 "$ROADIE_DATA_DIR/discord-sessions.db" "SELECT directory FROM channel_directories WHERE channel_id='c10'")" = "$KIMAKI_DATA/projects/never-copied" ]
check $? "stale binding without a copied project is reported, not rewritten"
[ "${#UPDATED_ITEMS[@]}" -gt "$UPDATED_ITEMS_BEFORE" ]; check $? "existing-copy relocation is reported in the summary"
[ "${#PENDING_ITEMS[@]}" -gt 0 ]; check $? "uncopied project paths block retiring the source"
roadie_migrate_from_kimaki
[ "$(printf '%s\n' "${UPDATED_ITEMS[@]}" | grep -c 'existing Roadie copy')" -eq 1 ]; check $? "repeat application adds no further summary item"

echo "==> ordinary bridge sync repairs paths after the legacy install is gone"
sqlite3 "$NEW_DB" "DELETE FROM channel_directories WHERE channel_id='c10'; UPDATE channel_directories SET directory='$KIMAKI_DATA/projects/demo' WHERE channel_id='c9';"
mv "$KIMAKI_DATA" "$TMP/retired-kimaki"
mv "$SYSTEMD_UNIT_DIR/kimaki.service" "$TMP/retired-kimaki.service"
_roadie_provision_package() { :; }
roadie_bin() { printf /usr/bin/roadie; }
_roadie_install_secrets() { :; }
_roadie_sync_assets() { :; }
_roadie_register_cli_channel() { :; }
DRY_RUN=true
bridge_sync_config
[ "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c9'")" = "$KIMAKI_DATA/projects/demo" ]; check $? "bridge dry-run leaves stored paths untouched"
DRY_RUN=false
bridge_sync_config
[ "$(sqlite3 "$NEW_DB" "SELECT directory FROM channel_directories WHERE channel_id='c9'")" = "$ROADIE_DATA_DIR/projects/demo" ]; check $? "ordinary bridge sync relocates bindings without a Kimaki unit or source database"
mv "$TMP/retired-kimaki" "$KIMAKI_DATA"
mv "$TMP/retired-kimaki.service" "$SYSTEMD_UNIT_DIR/kimaki.service"

echo "==> backend session history is preserved and blocks source cleanup"
mkdir -p "$SERVICE_HOME/.local/share/opencode"
BACKEND_DB="$SERVICE_HOME/.local/share/opencode/opencode.db"
sqlite3 "$BACKEND_DB" "CREATE TABLE session(id TEXT PRIMARY KEY, directory TEXT); INSERT INTO session VALUES ('backend-session','$KIMAKI_DATA/projects/demo');"
PENDING_ITEMS=()
bridge_sync_config
[ "${#PENDING_ITEMS[@]}" -eq 1 ]; check $? "backend directory dependencies are a cleanup blocker"
[ "$(sqlite3 "$BACKEND_DB" 'SELECT id FROM session')" = backend-session ] && [ "$(sqlite3 "$BACKEND_DB" 'SELECT directory FROM session')" = "$KIMAKI_DATA/projects/demo" ]; check $? "backend session identity and directory are not rewritten"
rm "$BACKEND_DB"

echo "==> a failed backup restarts Kimaki"
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
SQLITE3_READONLY_FAILS=1
( roadie_migrate_from_kimaki ) >/dev/null 2>&1
rc=$?
SQLITE3_READONLY_FAILS=0
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

echo "==> an old node refuses the migration before Kimaki is touched (#692)"
mv "$TMP/kimaki.service.away" "$SYSTEMD_UNIT_DIR/kimaki.service"
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
DATA_BEFORE_PREFLIGHT="$(cd "$KIMAKI_DATA" && find . -type f -exec cksum {} + | sort | grep -v 'discord-sessions.db-\(wal\|shm\)')"
NODE_MAJOR=22
( roadie_migrate_from_kimaki ) > "$TMP/preflight.out" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check $? "migration refused on node 22"
grep -q "node v22.0.0" "$TMP/preflight.out" && grep -q "needs Node >= 24" "$TMP/preflight.out"
check $? "refusal names the found version and the required floor"
grep -q "NodeSource" "$TMP/preflight.out"; check $? "refusal says how to fix it"
grep -q "Kimaki was left running" "$TMP/preflight.out" || grep -qi "kimaki" "$TMP/preflight.out"
check $? "refusal notes Kimaki was left running"
[ ! -s "$TMP/systemctl.log" ]; check $? "Kimaki not stopped or disabled"
[ ! -e "$ROADIE_DATA_DIR/discord-sessions.db" ]; check $? "no state copied to the Roadie data dir"
[ "$(cd "$KIMAKI_DATA" && find . -type f -exec cksum {} + | sort | grep -v 'discord-sessions.db-\(wal\|shm\)')" = "$DATA_BEFORE_PREFLIGHT" ]
check $? "Kimaki data dir untouched"

echo "==> dry-run with an old node reports the refusal instead of 'Would stop'"
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
( DRY_RUN=true; roadie_migrate_from_kimaki ) > "$TMP/preflight-dry.out" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "dry-run reports the refusal and continues"
grep -qF "Refusing the Kimaki → Roadie migration" "$TMP/preflight-dry.out"; check $? "refusal reported as a dry-run line"
if grep -qF "Would stop" "$TMP/preflight-dry.out"; then check 1 "no 'Would stop' line on refusal"; else check 0 "no 'Would stop' line on refusal"; fi
[ ! -s "$TMP/systemctl.log" ]; check $? "nothing stopped in dry-run either"
NODE_MAJOR=24

echo "==> migration completes but Roadie never gets healthy: roll back to Kimaki"
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
UPDATED_ITEMS=()
PENDING_ITEMS=()
curl() { if [ "$CURL_DISCORD_READY" = 1 ]; then printf '%s\n' '{"status":"ok","discordReady":true}'; fi; }
sleep() { :; }
journalctl() { printf 'journal %s\n' "$*" >> "$TMP/systemctl.log"; }
CURL_DISCORD_READY=0
error() { printf 'ERROR: %s\n' "$*" >> "$TMP/health-fail.out"; printf '%s\n' "${PENDING_ITEMS[@]}" > "$TMP/health-pending.out"; exit 1; }
( bridge_install ) > /dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ]; check $? "bridge_install fails when Roadie never becomes healthy"
grep -qx "stop kimaki.service" "$TMP/systemctl.log" && grep -qx "disable kimaki.service" "$TMP/systemctl.log"
check $? "the migration stopped and disabled Kimaki"
grep -qx "restart roadie.service" "$TMP/systemctl.log"; check $? "Roadie restarted for the health check"
grep -qx "stop roadie.service" "$TMP/systemctl.log" && grep -qx "disable roadie.service" "$TMP/systemctl.log"
check $? "unhealthy Roadie stopped and disabled"
grep -qx "enable kimaki.service" "$TMP/systemctl.log" && grep -qx "start kimaki.service" "$TMP/systemctl.log"
check $? "Kimaki re-enabled and restarted"
grep -qx "journal -u roadie.service -n 20 --no-pager" "$TMP/systemctl.log"; check $? "journal tail surfaced"
[ -f "$ROADIE_DATA_DIR/discord-sessions.db" ]; check $? "Roadie data dir kept for a retry"
grep -qF "never reported discordReady" "$TMP/health-pending.out"; check $? "pending item recorded"
grep -qF "Kimaki re-enabled and restarted" "$TMP/health-fail.out"; check $? "clear error printed"

echo "==> migration completes and Roadie is healthy: Kimaki stays disabled"
error() { echo -e "${RED}[wp-coding-agents]${NC} $1"; exit 1; }
CURL_DISCORD_READY=1
rm -rf "$ROADIE_DATA_DIR"
: > "$TMP/systemctl.log"
UPDATED_ITEMS=()
( bridge_install ) > "$TMP/health-ok.out" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "bridge_install succeeds when Roadie is healthy"
grep -qx "restart roadie.service" "$TMP/systemctl.log"; check $? "Roadie health-checked"
grep -qx "disable kimaki.service" "$TMP/systemctl.log"; check $? "migration disabled Kimaki"
if grep -qx "enable kimaki.service" "$TMP/systemctl.log" || grep -qx "start kimaki.service" "$TMP/systemctl.log"; then
  check 1 "healthy Roadie keeps Kimaki disabled"
else
  check 0 "healthy Roadie keeps Kimaki disabled"
fi
if grep -qx "stop roadie.service" "$TMP/systemctl.log"; then check 1 "healthy Roadie not torn down"; else check 0 "healthy Roadie not torn down"; fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-kimaki-migration.sh ($PASS assertions)"
