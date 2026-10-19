#!/bin/bash
# WordPress chat activation (#779) — the opt-in flag turns the merged
# #772/#773 pieces on as one unit, and stays inert without it.
#
# Covered here:
#   1. Disabled is a no-op: no env file, no connector unit, and the Roadie
#      env/render carries no ROADIE_PLATFORM or wordpress-chat lines. The
#      enabled render is the disabled render plus EXACTLY the two added lines
#      (byte-level), which is the "byte-identical without the flag" guarantee
#      from the other direction.
#   2. The signing secret is minted once into a 0600 env file and REUSED on a
#      second (upgrade) pass — including a pass that does not repeat the flag,
#      because the env file is the durable opt-in record.
#   3. The runtime-chat adapter config mu-plugin maps agent slug -> runtime ID
#      through the adapter_config filter (and the mapping actually resolves
#      when PHP is available).
#   4. channels.yaml gains a wordpress:<context> entry: created when missing,
#      inserted text-preservingly into an existing operator file (block and
#      flow style), idempotent, and keyed by the wordpress-context.json
#      context bound to the agent when that file exists.
#   5. The connector service unit is rendered/installed only when enabled,
#      loads the same env file the Roadie unit references, and execs the
#      installed connector next to its generated wp-control wrapper.
#
# tests/bridge-render.sh keeps the committed golden snapshots (rendered
# without the flag) honest; this file is separate because it needs its own
# hermetic temp config root (#776) rather than the host-managed roadie-config.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() { echo "FAIL: $1"; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }

# ---------------------------------------------------------------------------
# Deterministic mock host under a temp config root — nothing host-managed.
# ---------------------------------------------------------------------------
unset HOMEBOY_DATA_DIR ROADIE_CHANNELS_CONFIG ROADIE_PI_MODEL ROADIE_PI_BIN \
  ROADIE_POOL_URL WORDPRESS_CHAT_AGENT WORDPRESS_CHAT_RUNTIME_ID 2>/dev/null || true

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/roadie.sh"
source "$SCRIPT_DIR/lib/wordpress-chat.sh"

_resolve_node_bin_dir() { printf '/usr/bin'; }
systemctl() { printf '%s\n' "$*" >> "$TMP/systemctl-calls"; }
launchctl() { printf '%s\n' "$*" >> "$TMP/launchctl-calls"; }

LOCAL_MODE=false
DRY_RUN=false
PLATFORM=linux
SERVICE_USER=agent
SERVICE_HOME="$TMP/home"
SITE_PATH="$TMP/site"
ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
ROADIE_BIN=/usr/bin/roadie
ROADIE_CONFIG_DIR="$TMP/roadie-config"
ROADIE_SECRETS_ROOT="$TMP/secrets-root"
SYSTEMD_UNIT_DIR="$TMP/systemd"
WORDPRESS_CHAT_ENV_FILE="$TMP/secrets/wordpress-chat.env"
WORDPRESS_CHAT_CONNECTOR_DIR="$TMP/connector"
WORDPRESS_CHAT_LAUNCHD_DIR="$TMP/launchagents"
AGENT_SLUG=intelligence
WP_CMD=wp
UPDATED_ITEMS=()
PENDING_ITEMS=()
mkdir -p "$SERVICE_HOME" "$SITE_PATH" "$SYSTEMD_UNIT_DIR" "$ROADIE_CONFIG_DIR"

# ---------------------------------------------------------------------------
# 1. Without the flag everything is inert
# ---------------------------------------------------------------------------
wordpress_chat_enabled && fail "activation reports enabled without the flag or env file"
wordpress_chat_apply
[ -e "$WORDPRESS_CHAT_ENV_FILE" ] && fail "disabled apply wrote the env file"
[ -n "$(ls -A "$SYSTEMD_UNIT_DIR")" ] && fail "disabled apply installed a connector unit"
[ -e "$ROADIE_CONFIG_DIR/channels.yaml" ] && fail "disabled apply touched channels.yaml"
ok "disabled apply is a no-op (no env file, no connector unit, no channels.yaml)"

disabled_env="$(_roadie_append_env_files "$(_roadie_template_env /usr/bin)")"
grep -q 'ROADIE_PLATFORM' <<<"$disabled_env" && fail "disabled env block leaks ROADIE_PLATFORM"
grep -q 'wordpress-chat' <<<"$disabled_env" && fail "disabled env block leaks the wordpress-chat env file"
disabled_unit="$(bridge_render_systemd roadie.service "$disabled_env")"
grep -q 'ROADIE_PLATFORM' <<<"$disabled_unit" && fail "disabled Roadie unit carries ROADIE_PLATFORM"
grep -q 'wordpress-chat' <<<"$disabled_unit" && fail "disabled Roadie unit references the wordpress-chat env file"
ok "disabled Roadie render carries no wordpress-chat lines"

# ---------------------------------------------------------------------------
# 2. Secret minted once, 0600, reused on upgrade (flag repeated or not)
# ---------------------------------------------------------------------------
WORDPRESS_CHAT_AGENT=intelligence
wordpress_chat_write_env
[ -f "$WORDPRESS_CHAT_ENV_FILE" ] || fail "env file was not written"
mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$WORDPRESS_CHAT_ENV_FILE")"
[ "$mode" = "0o600" ] || fail "env file mode is $mode, expected 0600"
secret1="$(wordpress_chat_read_env_value WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET "$WORDPRESS_CHAT_ENV_FILE")"
[ -n "$secret1" ] || fail "no signing secret minted"
grep -q '^WP_CODING_AGENTS_INBOUND_WORDPRESS_ENABLED=1$' "$WORDPRESS_CHAT_ENV_FILE" || fail "env file missing ENABLED=1"
grep -q '^WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT=http://127.0.0.1:3712/wordpress/events$' "$WORDPRESS_CHAT_ENV_FILE" || fail "env file missing endpoint"
grep -q '^WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV=WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET$' "$WORDPRESS_CHAT_ENV_FILE" || fail "env file missing secret env name"
grep -q '^WP_CODING_AGENTS_RUNTIME_ID=roadie$' "$WORDPRESS_CHAT_ENV_FILE" || fail "env file missing runtime id"
ok "env file minted with 0600 mode, secret, endpoint, and runtime id"

# Upgrade pass with the flag repeated: secret unchanged.
wordpress_chat_write_env
[ "$(wordpress_chat_read_env_value WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET "$WORDPRESS_CHAT_ENV_FILE")" = "$secret1" ] \
  || fail "secret regenerated on upgrade with the flag"
# Upgrade pass WITHOUT the flag: env file is the durable record.
WORDPRESS_CHAT_AGENT=""
wordpress_chat_enabled || fail "env file does not re-enable activation on upgrade"
[ "$(wordpress_chat_agent_slug)" = intelligence ] || fail "agent slug not recovered from the env file"
[ "$(wordpress_chat_runtime_id)" = roadie ] || fail "runtime id not recovered from the env file"
wordpress_chat_write_env
[ "$(wordpress_chat_read_env_value WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET "$WORDPRESS_CHAT_ENV_FILE")" = "$secret1" ] \
  || fail "secret regenerated on upgrade without the flag"
ok "signing secret reused across upgrades, with and without the flag"

# ---------------------------------------------------------------------------
# 3. Enabled render = disabled render + exactly the two wordpress-chat lines
# ---------------------------------------------------------------------------
enabled_env="$(_roadie_append_env_files "$(_roadie_template_env /usr/bin)")"
grep -qx 'Environment=ROADIE_PLATFORM=discord,wordpress' <<<"$enabled_env" \
  || fail "enabled env block lacks ROADIE_PLATFORM=discord,wordpress"
grep -qxF "EnvironmentFile=-$WORDPRESS_CHAT_ENV_FILE" <<<"$enabled_env" \
  || fail "enabled env block lacks EnvironmentFile for the shared secret"
stripped="$(grep -vx 'Environment=ROADIE_PLATFORM=discord,wordpress' <<<"$enabled_env" \
  | grep -vxF "EnvironmentFile=-$WORDPRESS_CHAT_ENV_FILE")"
diff <(printf '%s\n' "$disabled_env") <(printf '%s\n' "$stripped") >/dev/null \
  || fail "enabled env block differs from disabled beyond the two wordpress-chat lines"
enabled_unit="$(bridge_render_systemd roadie.service "$enabled_env")"
stripped_unit="$(grep -vx 'Environment=ROADIE_PLATFORM=discord,wordpress' <<<"$enabled_unit" \
  | grep -vxF "EnvironmentFile=-$WORDPRESS_CHAT_ENV_FILE")"
diff <(printf '%s\n' "$disabled_unit") <(printf '%s\n' "$stripped_unit") >/dev/null \
  || fail "enabled Roadie unit differs from disabled beyond the two wordpress-chat lines"
ok "enabled Roadie render adds exactly ROADIE_PLATFORM and the EnvironmentFile line"

# launchd render inlines the platform list and the delivery env (incl. secret).
launchd_xml="$(_roadie_wordpress_chat_launchd_env_xml)"
grep -q '<key>ROADIE_PLATFORM</key>' <<<"$launchd_xml" || fail "launchd env XML lacks ROADIE_PLATFORM"
grep -q 'discord,wordpress' <<<"$launchd_xml" || fail "launchd env XML lacks the platform list"
grep -qF "$secret1" <<<"$launchd_xml" || fail "launchd env XML does not inline the shared secret"
saved_agent="$WORDPRESS_CHAT_AGENT"; WORDPRESS_CHAT_AGENT=""
saved_env_file="$WORDPRESS_CHAT_ENV_FILE"; WORDPRESS_CHAT_ENV_FILE="$TMP/nonexistent.env"
[ -z "$(_roadie_wordpress_chat_launchd_env_xml)" ] || fail "launchd env XML rendered while disabled"
WORDPRESS_CHAT_AGENT="$saved_agent"; WORDPRESS_CHAT_ENV_FILE="$saved_env_file"
ok "launchd env XML inlines the shared secret only when enabled"

# ---------------------------------------------------------------------------
# 4. runtime-chat adapter config: agent slug -> runtime ID
# ---------------------------------------------------------------------------
wordpress_chat_write_adapter_config
adapter_file="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtime-chat-config.php"
[ -f "$adapter_file" ] || fail "adapter config mu-plugin not written"
grep -qF "\$agents['intelligence'] = 'roadie';" "$adapter_file" || fail "adapter config lacks the slug -> runtime mapping"
grep -qF "wp_coding_agents_inbound_event_adapter_config" "$adapter_file" || fail "adapter config does not use the adapter-config filter"
if command -v php >/dev/null 2>&1; then
  php -l "$adapter_file" >/dev/null || fail "adapter config is not valid PHP"
  resolved="$(php -r '
    define( "ABSPATH", "/tmp/" );
    $filters = array();
    function add_filter( $hook, $callback ) { global $filters; $filters[ $hook ][] = $callback; }
    require $argv[1];
    $config = array( "runtime-chat" => array( "existing" => true ) );
    foreach ( $filters["wp_coding_agents_inbound_event_adapter_config"] as $callback ) { $config = $callback( $config ); }
    echo $config["runtime-chat"]["agents"]["intelligence"] . "|" . var_export( $config["runtime-chat"]["existing"], true );
  ' "$adapter_file")"
  [ "$resolved" = "roadie|true" ] || fail "adapter config filter resolved '$resolved', expected 'roadie|true'"
fi
ok "runtime-chat adapter config maps intelligence -> roadie through adapter_config()"

# ---------------------------------------------------------------------------
# 5. channels.yaml: created, inserted (block + flow), idempotent, context-bound
# ---------------------------------------------------------------------------
channels="$ROADIE_CONFIG_DIR/channels.yaml"
wordpress_chat_ensure_channel
grep -qF '"wordpress:intelligence": {}' "$channels" || fail "missing channels.yaml was not created with the channel"
before="$(cat "$channels")"
wordpress_chat_ensure_channel
[ "$before" = "$(cat "$channels")" ] || fail "second ensure-channel pass rewrote channels.yaml"
ok "channels.yaml created with wordpress:intelligence and left alone when present"

printf '# operator file\napplication:\n  channel: "123"\nchannels:\n  "123": {}\n' > "$channels"
wordpress_chat_ensure_channel
grep -qF '"wordpress:intelligence": {}' "$channels" || fail "channel not inserted into a block-style channels map"
grep -qF '"123": {}' "$channels" || fail "existing block-style entry lost"
grep -qF '# operator file' "$channels" || fail "operator comment lost"
printf 'channels: {"123": {}}\n' > "$channels"
wordpress_chat_ensure_channel
grep -qF '"wordpress:intelligence": {}, "123": {}' "$channels" || fail "channel not inserted into a flow-style channels map"
ok "channel inserted text-preservingly into block- and flow-style operator files"

printf '{"version":1,"contexts":{"prod":{"agentSlug":"intelligence","sitePath":"%s"}}}\n' "$SITE_PATH" \
  > "$ROADIE_CONFIG_DIR/wordpress-context.json"
[ "$(wordpress_chat_context_key)" = prod ] || fail "context key not resolved from wordpress-context.json"
rm -f "$channels"
wordpress_chat_ensure_channel
grep -qF '"wordpress:prod": {}' "$channels" || fail "channel entry not keyed by the bound context"
rm -f "$ROADIE_CONFIG_DIR/wordpress-context.json"
ok "channel entry follows the wordpress-context.json binding for the agent"

# ---------------------------------------------------------------------------
# 6. Connector: files + systemd unit only when enabled
# ---------------------------------------------------------------------------
wordpress_chat_install_connector_files
[ -x "$WORDPRESS_CHAT_CONNECTOR_DIR/inbound-event-connector" ] || fail "connector script not installed"
cmp -s "$WORDPRESS_CHAT_CONNECTOR_DIR/inbound-event-connector" "$SCRIPT_DIR/scripts/inbound-event-connector.py" \
  || fail "installed connector drifts from scripts/inbound-event-connector.py"
[ -x "$WORDPRESS_CHAT_CONNECTOR_DIR/wp-control" ] || fail "wp-control wrapper not installed"
grep -qF -- "--path=$SITE_PATH" "$WORDPRESS_CHAT_CONNECTOR_DIR/wp-control" || fail "wp-control wrapper not pinned to the site path"
ok "connector and wp-control wrapper installed next to each other"

wordpress_chat_install_connector_service
unit_file="$SYSTEMD_UNIT_DIR/wp-coding-agents-inbound-connector.service"
[ -f "$unit_file" ] || fail "connector systemd unit not written"
grep -qxF "EnvironmentFile=$WORDPRESS_CHAT_ENV_FILE" "$unit_file" || fail "connector unit does not load the shared env file"
grep -qxF "ExecStart=/usr/bin/env python3 $WORDPRESS_CHAT_CONNECTOR_DIR/inbound-event-connector" "$unit_file" \
  || fail "connector unit ExecStart wrong"
grep -qxF "User=agent" "$unit_file" || fail "connector unit does not run as the service user"
grep -qF 'After=network.target roadie.service' "$unit_file" || fail "connector unit not ordered after Roadie"
grep -q 'enable wp-coding-agents-inbound-connector.service' "$TMP/systemctl-calls" || fail "connector unit not enabled"
ok "connector systemd unit present, env-file-backed, ordered next to Roadie"

# Both processes read the same secret: the Roadie unit's EnvironmentFile and
# the connector unit's EnvironmentFile are the same path.
roadie_env_path="$(grep -ox "EnvironmentFile=-$WORDPRESS_CHAT_ENV_FILE" <<<"$enabled_env" | sed 's/^EnvironmentFile=-//')"
connector_env_path="$(sed -n 's/^EnvironmentFile=//p' "$unit_file")"
[ "$roadie_env_path" = "$connector_env_path" ] || fail "Roadie and connector read different env files"
ok "Roadie and connector share one signing-secret env file"

# Named Roadie instance renders a suffixed unit name and env path default.
suffixed_unit="$(ROADIE_UNIT=roadie-extrachill.service wordpress_chat_connector_unit)"
[ "$suffixed_unit" = "wp-coding-agents-inbound-connector-extrachill.service" ] || fail "instance suffix not applied to connector unit"
default_env="$(WORDPRESS_CHAT_ENV_FILE= ROADIE_UNIT=roadie-extrachill.service wordpress_chat_env_file)"
[ "$default_env" = "$ROADIE_SECRETS_ROOT/roadie-extrachill/wordpress-chat.env" ] || fail "instance suffix not applied to the env file path"
ok "named Roadie instances get suffixed connector unit and env file paths"

# launchd variant (local mac): plist written, env inlined, parseable.
LOCAL_MODE=true PLATFORM=mac wordpress_chat_install_connector_service
plist="$WORDPRESS_CHAT_LAUNCHD_DIR/com.wp.wp-coding-agents-inbound-connector.plist"
[ -f "$plist" ] || fail "connector launchd plist not written"
grep -qF "$secret1" "$plist" || fail "connector plist does not inline the shared secret"
python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$plist" || fail "connector plist is not valid"
grep -q 'bootstrap' "$TMP/launchctl-calls" || fail "connector plist not bootstrapped"
ok "connector launchd plist rendered with the inlined delivery env"

echo "wordpress-chat-activation: $PASS checks passed"
