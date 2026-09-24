#!/bin/bash
# Every rendered launchd plist is well-formed XML, including when the values
# interpolated into it contain XML metacharacters.
#
# WHY THIS EXISTS
#
# The plist document frame was copy-pasted into five renderers, and the copies
# disagreed about escaping: the two services ran their values through
# xml_escape, the three bridges interpolated them raw. Nothing noticed, because
# the snapshot fixtures use tidy values like /var/www/site — and a value with an
# ampersand in it produces a plist that launchd refuses to load, at which point
# the agent simply never starts.
#
# The snapshots prove the rendering is stable. This proves it is correct for
# values the snapshots never contain. Both matter: a golden file locks in
# whatever you rendered the day you wrote it, including a bug.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

source lib/common.sh
source lib/grants.sh

PASS=0
FAIL=0

# A value carrying every character XML cares about, in a shape a real install
# could plausibly produce: a path or token with an ampersand in it.
HOSTILE='a&b<c>d'

well_formed() {
  python3 -c 'import sys,xml.etree.ElementTree as ET; ET.fromstring(sys.stdin.read())' 2>&1
}

check_plist() {
  local name="$1" rendered="$2" err
  if err="$(printf '%s' "$rendered" | well_formed)"; then
    printf 'ok   %s renders well-formed XML with hostile values\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s is not well-formed XML\n       %s\n' "$name" "$err"
    printf '%s\n' "$rendered" | sed 's/^/       | /' | head -12
    FAIL=$((FAIL + 1))
  fi
}

# The value must survive escaping intact, not merely be stripped: a plist that
# parses but has lost half a path is worse than one that fails to load.
check_roundtrip() {
  local name="$1" rendered="$2" found
  found="$(printf '%s' "$rendered" | python3 -c '
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print("yes" if any((e.text or "").find(sys.argv[1]) >= 0 for e in root.iter("string")) else "no")
' "$HOSTILE" 2>/dev/null)"
  if [ "$found" = yes ]; then
    printf 'ok   %s preserves the value through escaping\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s lost or mangled the value\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Shared mock environment. Mirrors tests/bridge-render.sh, with the paths that
# reach a plist carrying XML metacharacters.
# ---------------------------------------------------------------------------

export PATH="/usr/bin:/bin"
export SERVICE_USER="chubes"
export SERVICE_HOME="/home/$HOSTILE"
export SITE_PATH="/var/www/$HOSTILE"
export PLATFORM="mac"
export LOCAL_MODE=true
export DRY_RUN=false
export INSTALL_CHAT=true
export RUN_AS_ROOT=false
export IS_STUDIO=false
export WP_CMD="wp"
export AGENT_SLUG="$HOSTILE"
export KIMAKI_LOCK_PORT=""

export KIMAKI_DATA_DIR="$SERVICE_HOME/.kimaki"
export KIMAKI_CONFIG_DIR="/opt/kimaki-config"
export KIMAKI_BIN="/usr/bin/kimaki"
export KIMAKI_BOT_TOKEN="tok$HOSTILE"

export CC_BIN="/usr/bin/cc-connect"
export CC_DATA_DIR="$SERVICE_HOME/.cc-connect"
export CC_CONNECT_TOKEN=""

export OPENCODE_BIN="/usr/bin/opencode"
export TELEGRAM_BIN="/usr/bin/opencode-telegram"
export SERVE_ENV_FILE="$SERVICE_HOME/.config/opencode-serve.env"
export TELEGRAM_CONFIG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"
export TELEGRAM_BOT_TOKEN="tok$HOSTILE"
export TELEGRAM_ALLOWED_USER_ID="123"
export OPENCODE_MODEL="prov/$HOSTILE"

source bridges/_dispatch.sh
_resolve_node_bin_dir() { printf ''; }

# ---------------------------------------------------------------------------
# Bridges
# ---------------------------------------------------------------------------

render_in_subshell() { ( bridge_load "$1" >/dev/null 2>&1; bridge_render_launchd "$2" ); }

CC="$(render_in_subshell cc-connect com.wp.cc-connect)"
check_plist "cc-connect" "$CC"
check_roundtrip "cc-connect" "$CC"

KIMAKI="$(render_in_subshell kimaki com.wp.kimaki)"
check_plist "kimaki" "$KIMAKI"
check_roundtrip "kimaki" "$KIMAKI"

TG_SERVE="$(render_in_subshell telegram com.wp.opencode-serve)"
check_plist "telegram opencode-serve" "$TG_SERVE"
check_roundtrip "telegram opencode-serve" "$TG_SERVE"

TG_BOT="$(render_in_subshell telegram com.wp.opencode-telegram)"
check_plist "telegram bot" "$TG_BOT"
check_roundtrip "telegram bot" "$TG_BOT"

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

WPS="$( source services/wordpress-service.sh
        WORDPRESS_SERVICE_PHP="/usr/bin/php"
        WORDPRESS_SERVICE_WP="/usr/local/bin/wp"
        WORDPRESS_SERVICE_HOST="127.0.0.1"
        WORDPRESS_SERVICE_PORT="8080"
        WORDPRESS_SERVICE_WORKERS="4"
        wordpress_service_render_launchd com.wp.wordpress-service )"
check_plist "wordpress-service" "$WPS"
check_roundtrip "wordpress-service" "$WPS"

DMW="$( source services/datamachine-worker.sh
        DATAMACHINE_WORKER_INTERVAL=120
        datamachine_worker_render_launchd com.wp.datamachine-worker )"
check_plist "datamachine-worker" "$DMW"
check_roundtrip "datamachine-worker" "$DMW"

# ---------------------------------------------------------------------------
# The frame itself
# ---------------------------------------------------------------------------

FRAME="$(printf '    <key>Label</key>\n    <string>%s</string>\n' "$(xml_escape "$HOSTILE")" | plist_document)"
check_plist "plist_document frame" "$FRAME"
check_roundtrip "plist_document frame" "$FRAME"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'PASS: tests/plist-rendering.sh\n'
