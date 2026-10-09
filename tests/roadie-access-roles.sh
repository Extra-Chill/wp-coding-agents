#!/bin/bash
# tests/roadie-access-roles.sh — the Kimaki → Roadie migration reconciles
# Discord access roles (#705).
#
# Roadie grants session access to the guild owner, Administrator, Manage
# Server, or a role named "roadie" (case-insensitive). Kimaki-era installs
# handed users a "kimaki" role, which Roadie stopped reading at roadie#32,
# so after a cutover every non-owner user is locked out until that role is
# renamed. Once the gateway is healthy the migration renames kimaki →
# Roadie with the bot token; when the bot cannot (no Manage Roles, an
# integration-managed role, a Discord error), the exact action lands in the
# upgrade summary instead — and a Discord hiccup never rolls the state
# migration back. The rename only ever follows a healthy gateway, and the
# upgrade pass replays it quietly for hosts cut over before #705.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
# check <description> <command...> — passes when the command succeeds.
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $desc"
    FAIL=$((FAIL + 1))
  fi
}

# Assertion helpers over the summary arrays and the recorded Discord calls.
pending_has() { printf '%s\n' "${PENDING_ITEMS[@]}" | grep -qF "$1"; }
updated_has() { printf '%s\n' "${UPDATED_ITEMS[@]}" | grep -qF "$1"; }
nothing_pending() { test "${#PENDING_ITEMS[@]}" -eq 0; }
nothing_updated() { test "${#UPDATED_ITEMS[@]}" -eq 0; }
empty_file() { test ! -s "$1"; }
patch_log_has() { grep -qx "$1" "$TMP/patch.log"; }
called() { grep -q "$1" "$TMP/curl.log"; }
not_called() { test ! -s "$TMP/curl.log"; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

log() { printf '%s\n' "$*" >> "$TMP/log"; }
warn() { printf '%s\n' "$*" >> "$TMP/warn.log"; }
sleep() { :; }
journalctl() { :; }
DRY_RUN=false
LOCAL_MODE=false
UPDATED_ITEMS=()
PENDING_ITEMS=()
ROADIE_UNIT=roadie.service
ROADIE_LOCK_PORT=29988
export WP_CODING_AGENTS_TEST_EUID=0
SYSTEMD_UNIT_DIR="$TMP/systemd"
SERVICE_HOME="$TMP/home"
ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
ROADIE_SECRETS_ROOT="$TMP/secrets"
mkdir -p "$SYSTEMD_UNIT_DIR" "$SERVICE_HOME"
printf '[Unit]\n[Service]\nExecStart=/usr/bin/roadie\n' > "$SYSTEMD_UNIT_DIR/roadie.service"

# Discord REST fixtures. Guild g1 ("H44 Lacrosse") is the migrated guild:
# @everyone plus h44-bot, plus any extra roles a scenario appends. 104324673
# is the stock @everyone permission set; 268435456 adds MANAGE_ROLES and 8
# is ADMINISTRATOR.
GUILD_NAME="H44 Lacrosse"
EVERYONE_PERMS="104324673"
MANAGE_ROLES_PERMS="372768129"
ADMIN_PERMS="8"
OWNER_ID="111"
BOT_ID="999"

guild_fixture() { # <extra role objects, each comma-prefixed>
  printf '{"id":"g1","name":"%s","owner_id":"%s","roles":[{"id":"g1","name":"@everyone","permissions":"%s","managed":false,"position":0},{"id":"r1","name":"h44-bot","permissions":"%s","managed":false,"position":3}%s]}' \
    "$GUILD_NAME" "$OWNER_ID" "$EVERYONE_PERMS" "$MANAGE_ROLES_PERMS" "${1:-}"
}

kimaki_role() { printf '{"id":"r2","name":"kimaki","permissions":"0","managed":false,"position":2}'; }
roadie_role() { printf '{"id":"r3","name":"%s","permissions":"0","managed":false,"position":2}' "$1"; }
member_fixture() { printf '{"user":{"id":"%s","username":"roadie","bot":true},"roles":[%s]}' "$1" "${2:-}"; }
count_equals() { test "$(grep -c "$1" "$2")" -eq "$3"; }

HEALTHY=1
DISCORD_GUILDS_RC=0
DISCORD_GUILD_RC=0
DISCORD_PATCH_RC=0
DISCORD_GUILDS='[{"id":"g1","name":"H44 Lacrosse"}]'
DISCORD_GUILD_G2="$(printf '{"id":"g2","name":"Other Guild","owner_id":"%s","roles":[{"id":"g2","name":"@everyone","permissions":"%s","managed":false,"position":0}]}' "$OWNER_ID" "$EVERYONE_PERMS")"
DISCORD_MEMBER_G2="$(member_fixture "$BOT_ID")"
# One stub for the gateway health probe and the Discord REST calls. GETs
# answer from the fixtures; the PATCH target and Authorization header are
# recorded for assertions. The header must arrive on stdin (-H @-): argv is
# logged too, so a token on the command line fails the ps-exposure check.
curl() {
  local url="" auth="" data=""
  printf '%s\n' "$*" >> "$TMP/argv.log"
  for url in "$@"; do :; done
  while [ $# -gt 0 ]; do
    case "$1" in
      -d) if [ $# -gt 1 ]; then data="$2"; shift; fi ;;
      @-) IFS= read -r auth || true ;;
    esac
    shift
  done
  if [ -n "$auth" ]; then printf '%s\n' "$auth" >> "$TMP/auth.log"; fi
  case "$url" in
    http://127.0.0.1:29988/health)
      if [ "$HEALTHY" = 1 ]; then printf '%s\n' '{"status":"ok","discordReady":true}'; fi
      ;;
    https://discord.com/api/v10/users/@me/guilds)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      if [ "$DISCORD_GUILDS_RC" -ne 0 ]; then return 1; fi
      printf '%s\n' "$DISCORD_GUILDS"
      ;;
    https://discord.com/api/v10/guilds/g1)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      if [ "$DISCORD_GUILD_RC" -ne 0 ]; then return 1; fi
      printf '%s\n' "$DISCORD_GUILD"
      ;;
    https://discord.com/api/v10/guilds/g1/members/@me)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      printf '%s\n' "$DISCORD_MEMBER"
      ;;
    https://discord.com/api/v10/guilds/g1/roles/*)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      if [ -n "$data" ]; then printf '%s\n' "$data" >> "$TMP/patch.log"; fi
      if [ "$DISCORD_PATCH_RC" -ne 0 ]; then return 1; fi
      ;;
    https://discord.com/api/v10/guilds/g2)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      printf '%s\n' "$DISCORD_GUILD_G2"
      ;;
    https://discord.com/api/v10/guilds/g2/members/@me)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      printf '%s\n' "$DISCORD_MEMBER_G2"
      ;;
    https://discord.com/api/v10/guilds/g2/roles/*)
      printf '%s\n' "$url" >> "$TMP/curl.log"
      if [ -n "$data" ]; then printf '%s\n' "g2 $data" >> "$TMP/patch.log"; fi
      ;;
    *) return 1 ;;
  esac
}
systemctl() {
  printf '%s\n' "$*" >> "$TMP/systemctl.log"
  if [ "$1" = is-active ]; then [ "$HEALTHY" = 1 ]; return; fi
  return 0
}

reset_scenario() {
  DISCORD_GUILD="$(guild_fixture ",$(kimaki_role)")"
  DISCORD_MEMBER="$(member_fixture "$BOT_ID" '"r1"')"
  DISCORD_GUILDS_RC=0
  DISCORD_GUILD_RC=0
  DISCORD_PATCH_RC=0
  HEALTHY=1
  DRY_RUN=false
  UPDATED_ITEMS=()
  PENDING_ITEMS=()
  ROADIE_BOT_TOKEN="test-bot-token"
  : > "$TMP/curl.log"
  : > "$TMP/patch.log"
  : > "$TMP/auth.log"
  : > "$TMP/argv.log"
  : > "$TMP/warn.log"
  : > "$TMP/log"
}

echo "==> a healthy gateway with Manage Roles renames the kimaki role"
reset_scenario
_roadie_migrate_access_roles
rc=$?
check "reconciliation never fails the caller (rc=$rc)" test "$rc" -eq 0
check "PATCH renames the role to Roadie" patch_log_has '{"name":"Roadie"}'
check "the kimaki role (r2) is the rename target" called "guilds/g1/roles/r2"
check "the bot token authenticates the call" grep -qF "Authorization: Bot test-bot-token" "$TMP/auth.log"
token_not_in_argv() { ! grep -qF test-bot-token "$TMP/argv.log"; }
check "the bot token never appears in curl argv (ps-visible)" token_not_in_argv
check "summary reports the rename" updated_has "renamed the kimaki Discord role to Roadie in $GUILD_NAME"
check "nothing pending" nothing_pending

echo "==> the token falls back to the token file"
reset_scenario
unset ROADIE_BOT_TOKEN
mkdir -p "$ROADIE_SECRETS_ROOT/roadie"
printf 'file-bot-token\n' > "$ROADIE_SECRETS_ROOT/roadie/bot-token"
_roadie_migrate_access_roles
check "token read from the secrets dir" grep -qF "Authorization: Bot file-bot-token" "$TMP/auth.log"

echo "==> guild owner and Administrator also authorize the rename"
reset_scenario
DISCORD_MEMBER="$(member_fixture "$OWNER_ID")"
_roadie_migrate_access_roles
check "the guild owner bot may rename" patch_log_has '{"name":"Roadie"}'
reset_scenario
DISCORD_GUILD="$(guild_fixture ",$(kimaki_role),{\"id\":\"r4\",\"name\":\"admin-helper\",\"permissions\":\"$ADMIN_PERMS\",\"managed\":false,\"position\":4}")"
DISCORD_MEMBER="$(member_fixture "$BOT_ID" '"r4"')"
_roadie_migrate_access_roles
check "the Administrator bit authorizes the rename" patch_log_has '{"name":"Roadie"}'

echo "==> without Manage Roles the exact action lands in the summary"
reset_scenario
DISCORD_MEMBER="$(member_fixture "$BOT_ID")"
_roadie_migrate_access_roles
check "no rename attempted" empty_file "$TMP/patch.log"
check "summary carries the exact rename action" pending_has "Rename the kimaki Discord role to Roadie in $GUILD_NAME"
check "the action explains the Roadie role gate" pending_has "Roadie grants session access to a role named Roadie"
check "nothing claimed as done" nothing_updated

echo "==> a Roadie role already present leaves the guild alone"
reset_scenario
DISCORD_GUILD="$(guild_fixture ",$(kimaki_role),$(roadie_role ROADIE)")"
_roadie_migrate_access_roles
check "no rename next to an existing (case-insensitive) Roadie role" empty_file "$TMP/patch.log"
check "the operator is told to assign the existing role" pending_has "A Roadie role already exists in $GUILD_NAME: assign it to the users holding kimaki"
check "nothing claimed as done" nothing_updated

echo "==> a guild without a kimaki role is untouched"
reset_scenario
DISCORD_GUILD="$(guild_fixture "")"
_roadie_migrate_access_roles
check "no rename" empty_file "$TMP/patch.log"
check "fresh guild stays quiet" nothing_pending

echo "==> an integration-managed kimaki role cannot be renamed"
reset_scenario
DISCORD_GUILD="$(guild_fixture ',{"id":"r2","name":"kimaki","permissions":"0","managed":true,"position":2}')"
_roadie_migrate_access_roles
check "no rename attempted against a managed role" empty_file "$TMP/patch.log"
check "manual action reported" pending_has "Rename the kimaki Discord role to Roadie in $GUILD_NAME"

echo "==> a failed rename falls back to the summary action"
reset_scenario
DISCORD_PATCH_RC=1
_roadie_migrate_access_roles
check "PATCH failure reported for manual action" pending_has "Rename the kimaki Discord role to Roadie in $GUILD_NAME"

echo "==> Discord API failures warn and never abort"
reset_scenario
DISCORD_GUILDS_RC=1
_roadie_migrate_access_roles
rc=$?
check "guild-list failure keeps rc=0" test "$rc" -eq 0
check "failure warned" grep -q "Could not list Discord guilds" "$TMP/warn.log"
check "the migration pass asks the operator to verify" pending_has "Verify the Discord access roles after the Kimaki → Roadie migration"
reset_scenario
DISCORD_GUILD_RC=1
_roadie_migrate_access_roles
check "per-guild failure reports the rename action" pending_has "Rename the kimaki Discord role to Roadie in $GUILD_NAME"

echo "==> quiet mode (the upgrade pass) keeps unverifiable guilds out of the summary"
reset_scenario
DISCORD_GUILDS_RC=1
_roadie_migrate_access_roles quiet
check "guild-list failure stays out of the summary" nothing_pending
reset_scenario
DISCORD_GUILD_RC=1
_roadie_migrate_access_roles quiet
check "unverifiable guild stays out of the summary" nothing_pending
check "still visible in the log" grep -q "could not verify the Discord access roles" "$TMP/log"
reset_scenario
DISCORD_MEMBER="$(member_fixture "$BOT_ID")"
_roadie_migrate_access_roles quiet
check "a confirmed kimaki role stays loud in quiet mode" pending_has "Rename the kimaki Discord role to Roadie in $GUILD_NAME"

echo "==> several guilds: only the one holding a kimaki role is touched"
reset_scenario
DISCORD_GUILDS='[{"id":"g1","name":"H44 Lacrosse"},{"id":"g2","name":"Other Guild"}]'
_roadie_migrate_access_roles
check "the second guild probed too" called "guilds/g2"
check "exactly one rename" count_equals "roles/r2" "$TMP/curl.log" 1
check "the fresh guild is not renamed" count_equals "^g2 " "$TMP/patch.log" 0
check "rename reported for the migrated guild" updated_has "in $GUILD_NAME"

echo "==> dry run reports the rename without PATCHing"
reset_scenario
DRY_RUN=true
_roadie_migrate_access_roles > "$TMP/dryrun.out"
check "dry-run line printed" grep -qF "Would rename the kimaki role to Roadie in $GUILD_NAME" "$TMP/dryrun.out"
check "dry run PATCHes nothing" empty_file "$TMP/patch.log"

echo "==> the rename replays idempotently"
reset_scenario
_roadie_migrate_access_roles
DISCORD_GUILD="$(guild_fixture ',{"id":"r2","name":"Roadie","permissions":"0","managed":false,"position":2}')"
UPDATED_ITEMS=()
PENDING_ITEMS=()
: > "$TMP/patch.log"
_roadie_migrate_access_roles
check "no second PATCH once the role is Roadie" empty_file "$TMP/patch.log"
check "converged run reports nothing" nothing_pending

echo "==> without a bot token nothing calls Discord"
reset_scenario
unset ROADIE_BOT_TOKEN
rm -rf "$ROADIE_SECRETS_ROOT"
_roadie_migrate_access_roles
check "no Discord call without a token" not_called
check "no summary item without a token" nothing_pending

echo "==> the role step runs only after the gateway proves healthy"
reset_scenario
mkdir -p "$ROADIE_SECRETS_ROOT/roadie"
printf 'test-bot-token\n' > "$ROADIE_SECRETS_ROOT/roadie/bot-token"
ROADIE_MIGRATED_THIS_RUN=0
ROADIE_MIGRATION_KIMAKI_UNIT=""
HEALTHY=1
_roadie_verify_migration_health
check "no migration this run: no gateway probe, no Discord calls" not_called
ROADIE_MIGRATED_THIS_RUN=1
HEALTHY=0
error() { printf 'ERROR: %s\n' "$*" >> "$TMP/unhealthy.out"; }
_roadie_verify_migration_health
check "unhealthy gateway: no Discord access-role calls" not_called
HEALTHY=1
_roadie_verify_migration_health
check "healthy gateway renames the kimaki role" patch_log_has '{"name":"Roadie"}'

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-access-roles.sh ($PASS assertions)"
