#!/bin/bash
# Opt-in WordPress-native chat activation (#779).
#
# The pieces from #772/#773 (durable agents/chat ingress through the inbound
# queue, the Roadie `wordpress` chat platform) are switched on as one unit by
# `--wordpress-chat-agent <slug>` on setup/upgrade:
#
#   1. runtime-chat adapter config — an installer-written mu-plugin maps the
#      agent slug to the runtime ID that claims its queued events, read by
#      WpCodingAgents_Runtime_Chat through adapter_config('runtime-chat').
#   2. shared signing secret — minted once into a 0600 env file loaded by
#      both processes (the Roadie unit via EnvironmentFile, the connector
#      unit directly); reused, never regenerated, on upgrade.
#   3. managed connector service — scripts/inbound-event-connector.py runs
#      next to Roadie (systemd unit on a VPS, launchd plist on local macOS),
#      claiming queued agents-chat events over a generated wp-control wrapper
#      and delivering them to the wordpress-platform loopback ingress.
#   4. Roadie platform list + channel — the rendered Roadie service carries
#      ROADIE_PLATFORM=discord,wordpress (roadie#297 comma list) and
#      ROADIE_CHANNELS_CONFIG gains a `wordpress:<context>` entry so
#      ensureRuntime() admits the bound context instead of refusing with
#      "Channel … is not configured".
#
# Once opted in, the env file is the durable record: upgrades converge without
# repeating the flag. Without the flag and without that file, every hook here
# is inert and rendered service output stays byte-identical to today's.

WORDPRESS_CHAT_AGENT="${WORDPRESS_CHAT_AGENT:-}"
WORDPRESS_CHAT_SECRET_ENV_NAME="WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET"

# Instance suffix derived from the Roadie unit, so a second instance
# (roadie-<name>.service) gets its own env file, connector dir, and unit.
wordpress_chat_instance_suffix() {
  local stem="${ROADIE_UNIT:-roadie.service}"
  stem="${stem%.service}"
  [ "$stem" = roadie ] || printf -- '-%s' "${stem#roadie-}"
}

# The 0600 env file both processes load. Lives with the other Roadie secrets.
wordpress_chat_env_file() {
  if [ -n "${WORDPRESS_CHAT_ENV_FILE:-}" ]; then
    printf '%s\n' "$WORDPRESS_CHAT_ENV_FILE"
  elif [ "${LOCAL_MODE:-false}" = true ]; then
    printf '%s/secrets/wordpress-chat.env\n' "${ROADIE_DATA_DIR:-$HOME/.roadie}"
  else
    printf '%s/roadie%s/wordpress-chat.env\n' "${ROADIE_SECRETS_ROOT:-/etc/wp-coding-agents}" "$(wordpress_chat_instance_suffix)"
  fi
}

wordpress_chat_read_env_value() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

# Enabled by the flag this run, or durably by the env file a previous opt-in
# wrote. The second branch is what keeps upgrades converging without the flag.
wordpress_chat_enabled() {
  [ -n "${WORDPRESS_CHAT_AGENT:-}" ] && return 0
  [ "$(wordpress_chat_read_env_value WP_CODING_AGENTS_INBOUND_WORDPRESS_ENABLED "$(wordpress_chat_env_file)")" = 1 ]
}

wordpress_chat_agent_slug() {
  if [ -n "${WORDPRESS_CHAT_AGENT:-}" ]; then
    printf '%s\n' "$WORDPRESS_CHAT_AGENT"
    return 0
  fi
  wordpress_chat_read_env_value WP_CODING_AGENTS_WORDPRESS_CHAT_AGENT "$(wordpress_chat_env_file)"
}

# The runtime ID the queued events are claimed under. It must match on the
# WordPress side (runtime-chat config) and the connector (WP_CODING_AGENTS_
# RUNTIME_ID), so both read the same resolution: explicit override, the env
# file a previous run recorded, else the Roadie instance name.
wordpress_chat_runtime_id() {
  local value="${WORDPRESS_CHAT_RUNTIME_ID:-}"
  [ -n "$value" ] || value="$(wordpress_chat_read_env_value WP_CODING_AGENTS_RUNTIME_ID "$(wordpress_chat_env_file)")"
  [ -n "$value" ] || value="roadie$(wordpress_chat_instance_suffix)"
  printf '%s\n' "$value"
}

wordpress_chat_endpoint() {
  printf '%s\n' "${WORDPRESS_CHAT_ENDPOINT:-http://127.0.0.1:3712/wordpress/events}"
}

# Roadie accepts several platforms via --platform/ROADIE_PLATFORM (roadie#297).
wordpress_chat_roadie_platform_value() {
  printf '%s\n' "${WORDPRESS_CHAT_ROADIE_PLATFORMS:-discord,wordpress}"
}

# The slug and runtime ID are interpolated into a PHP mu-plugin and a systemd
# unit, so they are validated against the exact patterns the runtime-chat
# handler and the connector enforce before they go anywhere.
wordpress_chat_validate() {
  local slug runtime_id
  slug="$(wordpress_chat_agent_slug)"
  [ -n "$slug" ] || error "--wordpress-chat-agent requires an agent slug"
  printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,190}$' \
    || error "Invalid --wordpress-chat-agent '$slug' (expected a lowercase agent slug)"
  runtime_id="$(wordpress_chat_runtime_id)"
  printf '%s' "$runtime_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,190}$' \
    || error "Invalid WordPress chat runtime id '$runtime_id'"
}

# Mint the shared signing secret once; every later run (upgrade) reuses it and
# only reconciles the non-secret keys around it. 0600, service-user-owned.
wordpress_chat_write_env() {
  wordpress_chat_enabled || return 0
  wordpress_chat_validate
  local env_file secret
  env_file="$(wordpress_chat_env_file)"
  secret="$(wordpress_chat_read_env_value "$WORDPRESS_CHAT_SECRET_ENV_NAME" "$env_file")"
  if [ "${DRY_RUN:-false}" = true ]; then
    if [ -n "$secret" ]; then
      echo -e "${BLUE}[dry-run]${NC} Would reuse the WordPress chat signing secret in $env_file"
    else
      echo -e "${BLUE}[dry-run]${NC} Would mint a WordPress chat signing secret into $env_file (0600)"
    fi
    return 0
  fi
  if [ -z "$secret" ]; then
    secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    [ -z "${UPDATED_ITEMS+x}" ] || UPDATED_ITEMS+=("WordPress chat signing secret ($env_file)")
  fi
  mkdir -p "$(dirname "$env_file")"
  local tmp="$env_file.tmp.$$"
  ( umask 077 && {
      printf 'WP_CODING_AGENTS_INBOUND_WORDPRESS_ENABLED=1\n'
      printf 'WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT=%s\n' "$(wordpress_chat_endpoint)"
      printf 'WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV=%s\n' "$WORDPRESS_CHAT_SECRET_ENV_NAME"
      printf '%s=%s\n' "$WORDPRESS_CHAT_SECRET_ENV_NAME" "$secret"
      printf 'WP_CODING_AGENTS_RUNTIME_ID=%s\n' "$(wordpress_chat_runtime_id)"
      printf 'WP_CODING_AGENTS_WORDPRESS_CHAT_AGENT=%s\n' "$(wordpress_chat_agent_slug)"
    } > "$tmp" )
  chmod 0600 "$tmp"
  if [ "${LOCAL_MODE:-false}" != true ] && [ -n "${SERVICE_USER:-}" ]; then
    chown "$SERVICE_USER:$SERVICE_USER" "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$env_file"
}

wordpress_chat_adapter_config_path() {
  printf '%s/wp-content/mu-plugins/wp-coding-agents-runtime-chat-config.php\n' "$SITE_PATH"
}

# The installer-written runtime-chat config: agent slug -> runtime ID, through
# the generic adapter-config filter the inbound bridge already reads. Values
# were validated above, so interpolation into single-quoted PHP is safe.
wordpress_chat_write_adapter_config() {
  wordpress_chat_enabled || return 0
  [ -n "${SITE_PATH:-}" ] || { warn "  wordpress_chat: SITE_PATH not set — skipping the runtime-chat config"; return 0; }
  local file slug runtime_id content
  file="$(wordpress_chat_adapter_config_path)"
  slug="$(wordpress_chat_agent_slug)"
  runtime_id="$(wordpress_chat_runtime_id)"
  content="<?php
/**
 * Plugin Name: wp-coding-agents - runtime chat binding
 * Description: Installer-written runtime-chat adapter config (agent slug to runtime ID). Managed by wp-coding-agents.
 */

defined( 'ABSPATH' ) || exit;

add_filter( 'wp_coding_agents_inbound_event_adapter_config', static function ( \$config ) {
	\$config = is_array( \$config ) ? \$config : array();
	\$entry = isset( \$config['runtime-chat'] ) && is_array( \$config['runtime-chat'] ) ? \$config['runtime-chat'] : array();
	\$agents = isset( \$entry['agents'] ) && is_array( \$entry['agents'] ) ? \$entry['agents'] : array();
	\$agents['$slug'] = '$runtime_id';
	\$entry['agents'] = \$agents;
	\$config['runtime-chat'] = \$entry;
	return \$config;
} );"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write runtime-chat adapter config: $file ($slug -> $runtime_id)"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ] || ! printf '%s\n' "$content" | cmp -s - "$file"; then
    printf '%s\n' "$content" > "$file"
    log "  Wrote runtime-chat adapter config: $file ($slug -> $runtime_id)"
    [ -z "${UPDATED_ITEMS+x}" ] || UPDATED_ITEMS+=("Runtime chat binding ($slug -> $runtime_id)")
  fi
  service_file_normalize_perms "$file"
}

wordpress_chat_config_dir() {
  if declare -F roadie_config_dir >/dev/null; then
    roadie_config_dir
    return 0
  fi
  printf '%s\n' "${ROADIE_CONFIG_DIR:-/opt/roadie-config}"
}

# The Roadie context serving this agent: the wordpress-context.json context
# whose agentSlug matches, falling back to the slug itself when the binding
# file does not exist yet (the operator writes it; the channel entry then
# already matches once they name the context after the agent).
wordpress_chat_context_key() {
  local slug config
  slug="$(wordpress_chat_agent_slug)"
  config="$(wordpress_chat_config_dir)/wordpress-context.json"
  if [ -f "$config" ]; then
    python3 - "$config" "$slug" <<'PY'
import json, sys
key = sys.argv[2]
try:
    config = json.load(open(sys.argv[1]))
    for context, binding in (config.get("contexts") or {}).items():
        if isinstance(binding, dict) and binding.get("agentSlug") == sys.argv[2]:
            key = context
            break
except (OSError, ValueError, AttributeError):
    pass
print(key)
PY
    return 0
  fi
  printf '%s\n' "$slug"
}

wordpress_chat_channels_file() {
  printf '%s\n' "${ROADIE_CHANNELS_CONFIG:-$(wordpress_chat_config_dir)/channels.yaml}"
}

# Ensure the `wordpress:<context>` channel resolves in ROADIE_CHANNELS_CONFIG
# (ensureRuntime refuses an unconfigured channel). channels.yaml is
# operator-owned policy, so the edit is text-preserving: a missing file is
# created, a block- or flow-style `channels:` mapping gains one entry, and
# anything this cannot edit safely becomes a pending item instead of a rewrite.
wordpress_chat_ensure_channel() {
  wordpress_chat_enabled || return 0
  local file channel outcome status=0
  file="$(wordpress_chat_channels_file)"
  channel="wordpress:$(wordpress_chat_context_key)"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would ensure channel \"$channel\" in $file"
    return 0
  fi
  outcome="$(python3 - "$file" "$channel" <<'PY'
import re, sys
from pathlib import Path

file = Path(sys.argv[1])
channel = sys.argv[2]
entry = '"%s": {}' % channel
if not file.exists():
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text("channels:\n  %s\n" % entry, encoding="utf-8")
    print("created")
    raise SystemExit
text = file.read_text(encoding="utf-8")
if channel in text:
    print("present")
    raise SystemExit
if not text.strip():
    file.write_text("channels:\n  %s\n" % entry, encoding="utf-8")
    print("created")
    raise SystemExit
lines = text.splitlines(keepends=True)
for index, line in enumerate(lines):
    if re.match(r"^channels:\s*(#.*)?$", line):
        lines.insert(index + 1, "  %s\n" % entry)
        file.write_text("".join(lines), encoding="utf-8")
        print("inserted")
        raise SystemExit
flow = re.search(r"^channels:\s*\{", text, flags=re.M)
if flow:
    position = flow.end()
    separator = "" if text[position:].lstrip().startswith("}") else ", "
    file.write_text(text[:position] + entry + separator + text[position:], encoding="utf-8")
    print("inserted")
    raise SystemExit
print("manual")
raise SystemExit(3)
PY
)" || status=$?
  case "$outcome" in
    created|inserted)
      log "  channels.yaml: $outcome \"$channel\" in $file"
      [ -z "${UPDATED_ITEMS+x}" ] || UPDATED_ITEMS+=("Roadie channel $channel ($file)")
      ;;
    present) ;;
    *)
      warn "  Could not add \"$channel\" to $file automatically (status $status)."
      warn "  Add it under channels: so Roadie admits the bound WordPress context."
      [ -z "${PENDING_ITEMS+x}" ] || PENDING_ITEMS+=("Roadie channels.yaml entry \"$channel\" in $file")
      ;;
  esac
  return 0
}

wordpress_chat_connector_dir() {
  if [ -n "${WORDPRESS_CHAT_CONNECTOR_DIR:-}" ]; then
    printf '%s\n' "$WORDPRESS_CHAT_CONNECTOR_DIR"
  elif [ "${LOCAL_MODE:-false}" = true ]; then
    printf '%s/inbound-connector\n' "${ROADIE_DATA_DIR:-$HOME/.roadie}"
  else
    printf '/usr/local/lib/wp-coding-agents/inbound-connector%s\n' "$(wordpress_chat_instance_suffix)"
  fi
}

wordpress_chat_connector_unit() {
  printf 'wp-coding-agents-inbound-connector%s.service\n' "$(wordpress_chat_instance_suffix)"
}

wordpress_chat_connector_label() {
  printf 'com.wp.wp-coding-agents-inbound-connector\n'
}

# The connector script plus the wp-control wrapper it polls through (it execs
# a sibling named wp-control; on a managed host that is this run's WP-CLI
# transport pinned to the site path).
wordpress_chat_install_connector_files() {
  local dir command
  dir="$(wordpress_chat_connector_dir)"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install the inbound-event-connector and wp-control wrapper into $dir"
    return 0
  fi
  mkdir -p "$dir"
  cp "$SCRIPT_DIR/scripts/inbound-event-connector.py" "$dir/inbound-event-connector"
  command="$(wp_cli_transport_display)"
  printf '#!/bin/sh\n# Managed by wp-coding-agents: WP-CLI control transport for the inbound connector.\nexec %s "$@" --path=%q --allow-root\n' \
    "$command" "$SITE_PATH" > "$dir/wp-control"
  chmod 0755 "$dir/inbound-event-connector" "$dir/wp-control"
}

wordpress_chat_render_connector_systemd() {
  cat <<EOF
[Unit]
Description=wp-coding-agents inbound event connector (WordPress chat)
After=network.target ${ROADIE_UNIT:-roadie.service}

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
Environment=HOME=$SERVICE_HOME
EnvironmentFile=$(wordpress_chat_env_file)
ExecStart=/usr/bin/env python3 $(wordpress_chat_connector_dir)/inbound-event-connector
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

# launchd has no EnvironmentFile, so the delivery env (secret included) is
# inlined from the 0600 env file at render time, like the AI gateway plist env.
wordpress_chat_render_connector_launchd() {
  local label="$1" env_file key value env_xml="" data_dir
  env_file="$(wordpress_chat_env_file)"
  data_dir="${ROADIE_DATA_DIR:-$HOME/.roadie}"
  for key in WP_CODING_AGENTS_INBOUND_WORDPRESS_ENABLED \
    WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT \
    WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV \
    "$WORDPRESS_CHAT_SECRET_ENV_NAME" \
    WP_CODING_AGENTS_RUNTIME_ID; do
    value="$(wordpress_chat_read_env_value "$key" "$env_file")"
    [ -n "$value" ] || continue
    env_xml="$env_xml
        <key>$key</key>
        <string>$(xml_escape "$value")</string>"
  done
  plist_document <<EOF
    <key>Label</key>
    <string>$(xml_escape "$label")</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>python3</string>
        <string>$(xml_escape "$(wordpress_chat_connector_dir)/inbound-event-connector")</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xml_escape "$SITE_PATH")</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$data_dir/inbound-connector.log")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$data_dir/inbound-connector.error.log")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$(xml_escape "${SERVICE_HOME:-$HOME}")</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>$env_xml
    </dict>
EOF
}

wordpress_chat_install_connector_service() {
  if [ "${LOCAL_MODE:-false}" = true ] && [ "${PLATFORM:-}" = mac ]; then
    local label plist_dir plist
    label="$(wordpress_chat_connector_label)"
    plist_dir="${WORDPRESS_CHAT_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
    plist="$plist_dir/$label.plist"
    run_cmd mkdir -p "$plist_dir"
    write_file "$plist" "$(wordpress_chat_render_connector_launchd "$label")"
    if [ "${DRY_RUN:-false}" = false ]; then
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
    log "WordPress chat connector: $label"
    return 0
  fi
  if [ "${LOCAL_MODE:-false}" = true ]; then
    log "Local mode: run the inbound connector manually with:"
    log "  set -a; . $(wordpress_chat_env_file); set +a; python3 $(wordpress_chat_connector_dir)/inbound-event-connector"
    return 0
  fi
  local unit_dir unit
  unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  unit="$(wordpress_chat_connector_unit)"
  write_file "$unit_dir/$unit" "$(wordpress_chat_render_connector_systemd)"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable "$unit"
  run_cmd systemctl restart "$unit"
  log "WordPress chat connector: $unit"
}

# One idempotent pass, called from setup and upgrade. No-op unless opted in.
wordpress_chat_apply() {
  wordpress_chat_enabled || return 0
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    warn "  --wordpress-chat-agent is not managed on the external WordPress profile; start the installed inbound-event-connector from the runtime environment instead"
    return 0
  fi
  log "WordPress chat: agent $(wordpress_chat_agent_slug) -> runtime $(wordpress_chat_runtime_id)"
  wordpress_chat_write_env
  wordpress_chat_write_adapter_config
  wordpress_chat_ensure_channel
  wordpress_chat_install_connector_files
  wordpress_chat_install_connector_service
}
