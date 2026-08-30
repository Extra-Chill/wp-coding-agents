#!/bin/bash
# tests/wp-cli-machine-output.sh — isolate WP-CLI scalar captures from PHP diagnostics.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/detect.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DIAGNOSTIC='Deprecated: Case statements followed by a semicolon (;) are deprecated, use a colon (:) instead in phar:///tmp/wp-cli.phar/vendor/react/promise/src/functions.php on line 369'
WARNING='PHP Warning: Undefined array key 0 in /tmp/example.php on line 1'

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $label"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
    exit 1
  fi
}

normal="$(printf 'http://localhost:8881\n' | wp_cli_strip_php_diagnostics)"
assert_eq "$normal" "http://localhost:8881" "normal scalar stdout is unchanged"

contaminated="$(printf '\n%s\nhttp://localhost:8881\n' "$DIAGNOSTIC" | wp_cli_strip_php_diagnostics)"
assert_eq "$contaminated" "http://localhost:8881" "leading PHP diagnostics are stripped from scalar stdout"

warning="$(printf '%s\n/var/log/nginx\n' "$WARNING" | wp_cli_strip_php_diagnostics)"
assert_eq "$warning" "/var/log/nginx" "leading PHP warnings are stripped from scalar stdout"

empty="$(printf '%s\n\n' "$DIAGNOSTIC" | wp_cli_strip_php_diagnostics)"
assert_eq "$empty" "" "diagnostic-only stdout becomes an empty payload"

SITE_PATH="$TMP/intelligence-chubes4"
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/wp" <<SH
#!/bin/sh
if [ "\$1 \$2 \$3" = "option get siteurl" ] && [ "\$4" = "--path=\$EXPECTED_SITE_PATH" ]; then
  printf '%s\nhttp://localhost:8881\n' "$DIAGNOSTIC"
  exit 0
fi
if [ "\$1 \$2 \$3" = "option get siteurl" ]; then
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_BIN/wp"
PATH="$FAKE_BIN:$PATH"

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
EXPECTED_SITE_PATH="$SITE_PATH"
export EXPECTED_SITE_PATH

detect_environment > "$TMP/detect.log"

assert_eq "$SITE_DOMAIN" "localhost:8881" "SITE_DOMAIN ignores a leading PHP diagnostic"
if grep -q "Existing WordPress at: $SITE_PATH (localhost:8881)" "$TMP/detect.log"; then
  :
else
  echo "FAIL: expected clean site identity in detect log"
  cat "$TMP/detect.log"
  exit 1
fi
if grep -q "Deprecated:" "$TMP/detect.log"; then
  echo "FAIL: detect log captured PHP diagnostic text into site identity"
  cat "$TMP/detect.log"
  exit 1
fi

SITE_PATH="$TMP/log-site"
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php"
DRY_RUN=false
SOURCE_LOG_PATHS_EXPLICIT=false
SOURCE_LOG_PATHS=""

wp_cmd() {
  if [ "$1 $2" = "option get" ] && [ "$3" = "$SOURCE_POLICY_LOG_OPTION" ]; then
    printf '%s\n/var/log/nginx /var/log/php\n' "$DIAGNOSTIC"
    return 0
  fi
  echo "unexpected wp_cmd call: $*" >&2
  return 1
}

source_policy_resolve_log_paths 2>/dev/null
assert_eq "$(source_policy_log_paths | tr '\n' ' ')" "/var/log/nginx /var/log/php " \
  "recorded log paths keep absolute payloads after a diagnostic prefix"

SOURCE_LOG_PATHS=""
wp_cmd() {
  if [ "$1 $2" = "option get" ] && [ "$3" = "$SOURCE_POLICY_LOG_OPTION" ]; then
    printf '%s\n' "$DIAGNOSTIC"
    return 0
  fi
  echo "unexpected wp_cmd call: $*" >&2
  return 1
}
source_policy_resolve_log_paths 2>/dev/null
assert_eq "$(source_policy_log_paths | tr '\n' ' ')" "" \
  "diagnostic-only option output does not become candidate log paths"

echo "OK: WP-CLI scalar captures isolate PHP diagnostics from machine payloads"
