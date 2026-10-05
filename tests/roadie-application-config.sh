#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grants.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/roadie.sh"
LOCAL_MODE=true
ROADIE_DATA_DIR="$TMP/.roadie"
ROADIE_BIN=/usr/bin/roadie
SITE_PATH="$TMP/site"
SERVICE_HOME="$TMP/home"
SERVICE_USER=agent
ROADIE_LOCK_PORT=""
AGENT_SLUG=""
WP_CMD=wp
WP_CLI_TRANSPORT=(wp)
IS_STUDIO=false
unset ROADIE_CHANNELS_CONFIG

# Missing policy remains optional; existing installations still start normally.
[[ "$(bridge_render_launchd com.wp.roadie)" != *'<key>ROADIE_CHANNELS_CONFIG</key>'* ]]
[[ "$(_roadie_template_env /usr/bin)" != *'Environment=ROADIE_CHANNELS_CONFIG='* ]]

mkdir -p "$(roadie_config_dir)"
config="$(roadie_config_dir)/channels.yaml"
printf 'application: {channel: "123", directory: /srv/context}\nchannels: {"123": {}}\n' > "$config"
before="$(cksum "$config")"
for iteration in 1 2; do
  plist="$(bridge_render_launchd com.wp.roadie)"
  [[ "$plist" == *'<key>ROADIE_CHANNELS_CONFIG</key>'* ]]
  [[ "$plist" == *"<string>$config</string>"* ]]
  [[ "$(_roadie_template_env /usr/bin)" == *"Environment=ROADIE_CHANNELS_CONFIG=\"$config\""* ]]
done
[[ "$(cksum "$config")" == "$before" ]]
ROADIE_CHANNELS_CONFIG="$TMP/missing-explicit-policy.yaml"
[[ "$(bridge_render_launchd com.wp.roadie)" == *"<string>$ROADIE_CHANNELS_CONFIG</string>"* ]]
[[ "$(_roadie_template_env /usr/bin)" == *"Environment=ROADIE_CHANNELS_CONFIG=\"$ROADIE_CHANNELS_CONFIG\""* ]]
printf 'OK: explicit application config reaches launchd and systemd without rewriting operator bindings\n'
