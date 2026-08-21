#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/wp-content/mu-plugins"
export SITE_PATH="$TMP" DRY_RUN=false
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/inbound-event-bridge.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/external-wordpress.sh"
log() { :; }
warn() { printf '%s\n' "$1" >&2; }
inbound_event_bridge_install
test -f "$TMP/wp-content/mu-plugins/wp-coding-agents-inbound-events.php"
cmp -s "$SCRIPT_DIR/templates/wp-coding-agents-inbound-events.php" "$TMP/wp-content/mu-plugins/wp-coding-agents-inbound-events.php"
php -l "$TMP/wp-content/mu-plugins/wp-coding-agents-inbound-events.php" >/dev/null
export EXTERNAL_WORDPRESS=true RUNTIME_PROJECT_ROOT="$TMP/runtime"
inbound_event_connector_install
test -x "$TMP/runtime/.wp-coding-agents/bin/inbound-event-connector"
cmp -s "$SCRIPT_DIR/scripts/inbound-event-connector.py" "$TMP/runtime/.wp-coding-agents/bin/inbound-event-connector"
echo "OK: inbound event bridge installation assertions passed"
