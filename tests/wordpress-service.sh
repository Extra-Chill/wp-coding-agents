#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -r "$root"' EXIT

export SITE_PATH="$root/site & one" SERVICE_HOME="$root/home" LOCAL_MODE=true PLATFORM=mac DRY_RUN=false
export WORDPRESS_SERVICE_LAUNCHD_DIR="$root/LaunchAgents"
mkdir -p "$SITE_PATH" "$SERVICE_HOME" "$WORDPRESS_SERVICE_LAUNCHD_DIR" "$root/bin"
printf '#!/bin/sh\n' > "$root/bin/wp"
chmod +x "$root/bin/wp"
PATH="$root/bin:$PATH"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/services/wordpress-service.sh"

launchctl() { printf 'launchctl %s\n' "$*" >> "$root/calls"; }
wp_cli_transport_set wp

WORDPRESS_SERVICE_REQUEST=enabled
WORDPRESS_SERVICE_HOST=127.0.0.1
WORDPRESS_SERVICE_PORT=8881
wordpress_service_reconcile >/dev/null

label="$(wordpress_service_label)"
plist="$WORDPRESS_SERVICE_LAUNCHD_DIR/$label.plist"
[ -f "$plist" ]
[ -f "$(wordpress_service_state_file)" ]
grep -q 'host=127.0.0.1' "$(wordpress_service_state_file)"
grep -q 'port=8881' "$(wordpress_service_state_file)"
grep -q 'launchctl bootstrap' "$root/calls"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$plist" >/dev/null
  [ "$(plutil -extract ProgramArguments.0 raw -o - "$plist")" = "$root/bin/wp" ]
  [ "$(plutil -extract ProgramArguments.2 raw -o - "$plist")" = "--path=$SITE_PATH" ]
  [ "$(plutil -extract ProgramArguments.3 raw -o - "$plist")" = "--host=127.0.0.1" ]
  [ "$(plutil -extract ProgramArguments.4 raw -o - "$plist")" = "--port=8881" ]
fi

first_label="$label"
SITE_PATH="$root/site-two"
mkdir -p "$SITE_PATH"
[ "$(wordpress_service_label)" != "$first_label" ]

SITE_PATH="$root/site & one"
WORDPRESS_SERVICE_REQUEST=disabled
wordpress_service_reconcile >/dev/null
[ ! -e "$plist" ]
[ ! -e "$(wordpress_service_state_file)" ]

echo "PASS: tests/wordpress-service.sh"
