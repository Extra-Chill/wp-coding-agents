#!/bin/bash
# tests/detect-site-domain.sh — existing-site domain detection coverage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/detect.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/intelligence-chubes4"
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php" "$SITE_PATH/STUDIO.md"

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/studio" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUDIO_LOG"
if [ "$1 $2 $3 $4" = "wp option get siteurl" ] && [ "$5" = "--path=$EXPECTED_SITE_PATH" ]; then
  printf 'http://intelligence-chubes4.local\n'
  exit 0
fi
if [ "$1 $2 $3 $4" = "wp option get siteurl" ]; then
  exit 0
fi
if [ "$1" = "--version" ]; then
  printf '1.0.0\n'
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_BIN/studio"
cat > "$FAKE_BIN/wp" <<'SH'
#!/bin/sh
if [ "$1 $2 $3" = "option get siteurl" ] && [ "$4" = "--path=$EXPECTED_SITE_PATH" ]; then
  printf 'http://intelligence-chubes4.local\n'
  exit 0
fi
if [ "$1 $2 $3" = "option get siteurl" ]; then
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_BIN/wp"
PATH="$FAKE_BIN:$PATH"
EXPECTED_SITE_PATH="$SITE_PATH"
STUDIO_LOG="$TMP/studio.log"
: > "$STUDIO_LOG"
export EXPECTED_SITE_PATH STUDIO_LOG

OS=""
PLATFORM=""
LOCAL_MODE=true
MODE="existing"
SKIP_DEPS=true
SKIP_SSL=true
RUN_AS_ROOT=false
DRY_RUN=false
EXISTING_WP="$SITE_PATH"
RUNTIME="opencode"
MULTISITE=false
MULTISITE_TYPE="subdirectory"
SITE_DOMAIN=""
WP_CMD=""

detect_environment > "$TMP/output.log"

if [ "$(wp_cli_transport_display)" != "wp" ] || [ -s "$STUDIO_LOG" ]; then
  echo "FAIL: Studio detection did not prefer the usable direct wp transport"
  cat "$TMP/output.log" "$STUDIO_LOG"
  exit 1
fi

if [ "$SITE_DOMAIN" != "intelligence-chubes4.local" ]; then
  echo "FAIL: expected SITE_DOMAIN from the path-scoped wp transport, got '$SITE_DOMAIN'"
  cat "$TMP/output.log"
  exit 1
fi

if ! grep -q "Existing WordPress at: $SITE_PATH (intelligence-chubes4.local)" "$TMP/output.log"; then
  echo "FAIL: expected log to include path-scoped site domain"
  cat "$TMP/output.log"
  exit 1
fi

SITE_DOMAIN=""
detected_site_domain=""
EXPECTED_SITE_PATH="$TMP/other-site"
detect_environment > "$TMP/fallback-output.log"

if [ "$SITE_DOMAIN" != "intelligence-chubes4" ]; then
  echo "FAIL: expected SITE_DOMAIN fallback to basename when siteurl is empty, got '$SITE_DOMAIN'"
  cat "$TMP/fallback-output.log"
  exit 1
fi

SITE_DOMAIN=""
EXPECTED_SITE_PATH="$SITE_PATH"
WP_CMD="studio wp"
detect_environment > "$TMP/studio-output.log"
if [ "$SITE_DOMAIN" != "intelligence-chubes4.local" ] || [ ! -s "$STUDIO_LOG" ]; then
  echo "FAIL: explicit Studio transport was not preserved and invoked"
  cat "$TMP/studio-output.log" "$STUDIO_LOG"
  exit 1
fi

rm "$FAKE_BIN/wp"
SITE_DOMAIN=""
WP_CMD=""
: > "$STUDIO_LOG"
detect_environment > "$TMP/studio-fallback-output.log"
if [ "$(wp_cli_transport_display)" != "studio wp" ] || [ "$SITE_DOMAIN" != "intelligence-chubes4.local" ] || [ ! -s "$STUDIO_LOG" ]; then
  echo "FAIL: unusable direct WP-CLI did not fall back to the Studio transport"
  cat "$TMP/studio-fallback-output.log" "$STUDIO_LOG"
  exit 1
fi

RUN_LOG="$TMP/run-command.log"
run_cmd() {
  printf '<%s>' "$@" > "$RUN_LOG"
}
IS_STUDIO=true
wp_cli_transport_set wp
WP_ROOT_FLAG=""
wp_cmd option get siteurl
if [ "$(cat "$RUN_LOG")" != "<wp><option><get><siteurl><--path=$SITE_PATH>" ]; then
  echo "FAIL: wp_cmd ignored the explicit default transport"
  cat "$RUN_LOG"
  exit 1
fi
wp_cli_transport_set studio wp
wp_cmd option get siteurl
if [ "$(cat "$RUN_LOG")" != "<studio><wp><option><get><siteurl><--path=$SITE_PATH>" ]; then
  echo "FAIL: wp_cmd did not preserve the explicit Studio transport"
  cat "$RUN_LOG"
  exit 1
fi

WP_CMD=""
EXISTING_WP="$SITE_PATH"
detect_plugins_only_environment > "$TMP/plugins-only-output.log"
if [ "$(wp_cli_transport_display)" != "studio wp" ]; then
  echo "FAIL: plugin-only detection did not select the available Studio fallback"
  cat "$TMP/plugins-only-output.log"
  exit 1
fi
WP_CMD="wp"
detect_plugins_only_environment > "$TMP/plugins-only-explicit-output.log"
if [ "$(wp_cli_transport_display)" != "wp" ]; then
  echo "FAIL: plugin-only detection replaced the explicit wp transport"
  cat "$TMP/plugins-only-explicit-output.log"
  exit 1
fi

echo "OK: WordPress transport selection is capability-first and path-scoped"
