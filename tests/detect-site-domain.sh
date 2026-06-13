#!/bin/bash
# tests/detect-site-domain.sh — existing-site domain detection coverage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/detect.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/intelligence-chubes4"
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php" "$SITE_PATH/STUDIO.md"

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/studio" <<'SH'
#!/bin/sh
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
PATH="$FAKE_BIN:$PATH"
EXPECTED_SITE_PATH="$SITE_PATH"
export EXPECTED_SITE_PATH

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
WP_CMD="wp"

detect_environment > "$TMP/output.log"

if [ "$SITE_DOMAIN" != "intelligence-chubes4.local" ]; then
  echo "FAIL: expected SITE_DOMAIN from path-scoped Studio siteurl, got '$SITE_DOMAIN'"
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

echo "OK: existing-site domain detection scopes Studio WP-CLI to the site path and falls back when empty"
