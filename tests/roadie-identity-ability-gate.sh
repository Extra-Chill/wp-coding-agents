#!/bin/bash
# tests/roadie-identity-ability-gate.sh — the Roadie bridge step refuses to
# switch to the resolve-chat-person identity plugins on a site whose Data
# Machine does not provide that ability (#793).
#
# wordpress-context.mjs and wordpress-platform.mjs call Data Machine's
# datamachine/resolve-chat-person ability (first in Data Machine v0.184.0).
# A Data Machine installed from a release zip is not updated by upgrade.sh, so
# on 0.183.x the upgrade used to install the new plugin, drop the retired
# wordpress-context.php, add wordpress-platform.mjs to ROADIE_PLUGINS and exit
# 0 — and every Discord user was denied after the next restart.
#
# Driven through the real bridge adapter (bridge_sync_config then
# bridge_update_launchd) against a stubbed `wp`:
#   - ability missing  -> step fails, plugin files and the plist unchanged
#   - ability present  -> plugins install and ROADIE_PLUGINS converges as before
#   - legacy `people`  -> exact chat-identity link commands are printed
#   - --dry-run        -> same verdict, nothing written
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/bridge-service-adapters.sh"

INSTALLATION_OPERATION_SETUP=setup
INSTALLATION_OPERATION_UPGRADE=upgrade
BRIDGE_SERVICE_ADAPTER_OPERATION=upgrade
reconciler_adapter_changed() { :; }

# Everything around the gate that would reach the network or launchd.
_roadie_provision_package() { :; }
roadie_bin() { printf '/usr/bin/roadie\n'; }
_roadie_select_pi() { :; }
_roadie_remote_pool_ready() { return 0; }
_roadie_install_secrets() { :; }
_roadie_reconcile_existing_project_paths() { :; }
_roadie_register_cli_channel() { :; }
_roadie_install_upgrade_launchd() { :; }
launchctl() { :; }

export HOME="$TMP/home"
SITE_PATH="$TMP/site"
LOCAL_MODE=true
PLATFORM=mac
CHAT_BRIDGE=roadie
EXTERNAL_WORDPRESS=false
ROADIE_DATA_DIR="$HOME/.roadie"
ROADIE_PI_MODEL_EXPLICIT=true
ROADIE_PI_TITLE_MODEL_EXPLICIT=true
ROADIE_POOL_URL_EXPLICIT=true
SERVICE_HOME="$HOME"
TIMESTAMP=test
WP_ROOT_FLAG=""
mkdir -p "$SITE_PATH" "$HOME/Library/LaunchAgents" "$TMP/bin"

# Stubbed WP-CLI: answers the ability probe from STUB_ABILITY and logs argv.
cat > "$TMP/bin/wp" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_WP_LOG"
[ "$1" = eval ] || exit 1
case "$2" in
  *"wp_get_ability( 'datamachine/resolve-chat-person' )"*) ;;
  *) echo "unexpected eval" >&2; exit 1 ;;
esac
[ "$STUB_ABILITY" = present ] && echo ability:present || echo ability:missing
SH
chmod +x "$TMP/bin/wp"
export STUB_WP_LOG="$TMP/wp.log"
WP_CLI_TRANSPORT=("$TMP/bin/wp")

CONFIG_DIR="$(roadie_config_dir)"
PLUGINS_DIR="$(roadie_plugins_dir)"
PLIST="$HOME/Library/LaunchAgents/com.wp.roadie.plist"
OLD_PLUGINS="$PLUGINS_DIR/host-upgrade.mjs,$PLUGINS_DIR/wordpress-context.mjs,$PLUGINS_DIR/fork-workspace.mjs"

# A host as it was before #711: the old context plugin with its PHP resolver,
# a people map, and a plist without wordpress-platform.mjs.
seed_host() {
  rm -rf "$CONFIG_DIR" "$PLIST" "$STUB_WP_LOG"
  mkdir -p "$PLUGINS_DIR"
  printf '// old wordpress-context.mjs (people map)\n' > "$PLUGINS_DIR/wordpress-context.mjs"
  printf '<?php // old resolver\n' > "$PLUGINS_DIR/wordpress-context.php"
  cat > "$CONFIG_DIR/wordpress-context.json" <<'JSON'
{
  "version": 1,
  "defaultContext": "site",
  "contexts": {"site": {"sitePath": "/srv/site", "agentSlug": "bot"}},
  "people": {
    "discord:111111:222222": {"userId": 12, "capabilities": ["sessions", "shell"]},
    "discord:999999:222222": {"userId": 12, "capabilities": ["sessions"]},
    "slack:T0ABC:U0XYZ": {"userId": 23, "capabilities": ["sessions"]}
  }
}
JSON
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>EnvironmentVariables</key>
<dict>
<key>ROADIE_PLUGINS</key>
<string>$OLD_PLUGINS</string>
</dict>
</dict></plist>
PLIST_EOF
}

snapshot() { (cd "$CONFIG_DIR" && find . -type f | sort | xargs cksum; cksum < "$PLIST"); }

run_bridge_step() {
  UPDATED_ITEMS=()
  PENDING_ITEMS=()
  ( bridge_service_adapter_apply_bridge ) > "$TMP/out" 2>&1
}

echo "==> ability missing: the bridge step fails and changes nothing"
seed_host
export STUB_ABILITY=missing
DRY_RUN=false
BEFORE="$(snapshot)"
run_bridge_step; rc=$?
[ "$rc" -ne 0 ]; check $? "bridge step exits non-zero"
[ "$BEFORE" = "$(snapshot)" ]; check $? "plugin files, wordpress-context.json and plist unchanged"
[ -f "$PLUGINS_DIR/wordpress-context.php" ]; check $? "retired wordpress-context.php kept in place"
[ ! -e "$PLUGINS_DIR/wordpress-platform.mjs" ]; check $? "wordpress-platform.mjs not installed"
! grep -q 'wordpress-platform.mjs' "$PLIST"; check $? "ROADIE_PLUGINS not switched"
grep -q 'datamachine/resolve-chat-person' "$TMP/out"; check $? "failure names the missing ability"
grep -q 'Data Machine >= v0.184.0' "$TMP/out"; check $? "failure names the required Data Machine version"
grep -q 'data-machine.zip' "$TMP/out"; check $? "failure says how to update Data Machine"
grep -q '^eval ' "$STUB_WP_LOG"; check $? "ability probed through WP-CLI"

echo "==> legacy people map: exact chat-identity link commands are printed"
grep -qF 'wp datamachine chat-identity link discord 222222 --target-user=12' "$TMP/out"; check $? "discord actor id is the key's last segment"
grep -qF 'wp datamachine chat-identity link slack U0XYZ --target-user=23' "$TMP/out"; check $? "slack actor linked to its user"
[ "$(grep -cF 'chat-identity link discord 222222' "$TMP/out")" -eq 1 ]; check $? "one link per actor across guilds"

echo "==> ability missing under --dry-run: same verdict, nothing written"
seed_host
DRY_RUN=true
BEFORE="$(snapshot)"
run_bridge_step; rc=$?
[ "$rc" -ne 0 ]; check $? "dry-run bridge step reports the failure"
grep -q '\[dry-run\] Roadie bridge step failed' "$TMP/out"; check $? "dry-run failure is labelled"
grep -qF 'wp datamachine chat-identity link discord 222222 --target-user=12' "$TMP/out"; check $? "dry-run still prints the link commands"
[ "$BEFORE" = "$(snapshot)" ]; check $? "dry-run leaves files and plist unchanged"

echo "==> ability present under --dry-run: nothing written"
export STUB_ABILITY=present
BEFORE="$(snapshot)"
run_bridge_step; rc=$?
[ "$rc" -eq 0 ]; check $? "dry-run bridge step succeeds"
[ "$BEFORE" = "$(snapshot)" ]; check $? "dry-run writes nothing"

echo "==> ability present: plugins install as before"
DRY_RUN=false
run_bridge_step; rc=$?
[ "$rc" -eq 0 ] || cat "$TMP/out"
[ "$rc" -eq 0 ]; check $? "bridge step succeeds"
cmp -s "$SCRIPT_DIR/bridges/roadie/roadie-plugins/wordpress-context.mjs" "$PLUGINS_DIR/wordpress-context.mjs"; check $? "new wordpress-context.mjs installed"
cmp -s "$SCRIPT_DIR/bridges/roadie/roadie-plugins/wordpress-platform.mjs" "$PLUGINS_DIR/wordpress-platform.mjs"; check $? "wordpress-platform.mjs installed"
[ ! -e "$PLUGINS_DIR/wordpress-context.php" ]; check $? "retired wordpress-context.php removed"
[ "$(_plist_string_after_key "$PLIST" ROADIE_PLUGINS)" = "$(roadie_plugins_value)" ]; check $? "ROADIE_PLUGINS carries the managed set with wordpress-platform.mjs"
grep -qF 'wp datamachine chat-identity link discord 222222 --target-user=12' "$TMP/out"; check $? "link commands printed on a successful switch too"

echo "==> no wordpress-context.json: nothing to verify"
rm -f "$CONFIG_DIR/wordpress-context.json" "$STUB_WP_LOG"
export STUB_ABILITY=missing
run_bridge_step; rc=$?
[ "$rc" -eq 0 ]; check $? "bridge step succeeds without a context config"
[ ! -e "$STUB_WP_LOG" ]; check $? "WP-CLI not consulted"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: $FAIL check(s) failed"
  exit 1
fi
echo "PASS: Roadie identity plugins gated on datamachine/resolve-chat-person"
