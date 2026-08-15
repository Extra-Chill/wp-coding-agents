#!/bin/bash
# tests/ai-gateway.sh — regression tests for optional WP AI Gateway integration.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source lib/ai-gateway.sh
# shellcheck disable=SC1091
source bridges/_dispatch.sh

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       expected: '$expected'"
    echo "       actual:   '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_file_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF "$needle" "$file"; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       expected $file to contain: $needle"
    FAIL=$((FAIL+1))
  fi
}

assert_lacks() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       did not expect output to contain: $needle"
    FAIL=$((FAIL+1))
  fi
}

SITE_PATH="$TMPDIR_TEST/site"
SITE_DOMAIN="example.test"
WP_CMD="wp"
WP_ROOT_FLAG="--allow-root"
LOCAL_MODE=true
DRY_RUN=false
WITH_AI_GATEWAY=true
ROTATE_AI_GATEWAY_TOKEN=false
DETECTED_RUNTIMES=(opencode)
UPDATED_ITEMS=()
mkdir -p "$SITE_PATH/.opencode"

echo "==> existing gateway env is reused instead of rotated"
cat > "$SITE_PATH/.opencode/wp-ai-gateway.env" <<'EOF'
OPENAI_BASE_URL=https://old.example/wp-json/wp-ai-gateway/v1
OPENAI_API_KEY=wpag_existing_secret
EOF

ai_gateway_write_env
assert_file_contains "existing token preserved" "$SITE_PATH/.opencode/wp-ai-gateway.env" "OPENAI_API_KEY=wpag_existing_secret"
assert_file_contains "base URL refreshed" "$SITE_PATH/.opencode/wp-ai-gateway.env" "OPENAI_BASE_URL=https://example.test/wp-json/wp-ai-gateway/v1"

echo "==> dry-run redacts gateway token material"
DRY_RUN=true
ROTATE_AI_GATEWAY_TOKEN=true
DRY_OUTPUT="$(ai_gateway_write_env 2>&1)"
assert_lacks "dry-run does not print existing token" "$DRY_OUTPUT" "wpag_existing_secret"
assert_lacks "dry-run does not print fake token" "$DRY_OUTPUT" "wpag_"
assert_file_contains "dry-run leaves env token untouched" "$SITE_PATH/.opencode/wp-ai-gateway.env" "OPENAI_API_KEY=wpag_existing_secret"

echo "==> unit/plist dry-run diffs redact secrets"
REDACTED="$(printf '%s\n' '+Environment=OPENAI_API_KEY=wpag_existing_secret' ' <key>KIMAKI_BOT_TOKEN</key>' ' <string>discord_secret</string>' | _redact_secret_diff)"
assert_lacks "systemd-style secret redacted" "$REDACTED" "wpag_existing_secret"
assert_lacks "plist-style secret redacted" "$REDACTED" "discord_secret"

echo "==> Kimaki launchd inherits gateway environment"
# shellcheck disable=SC1091
source bridges/kimaki.sh
KIMAKI_BIN="/usr/bin/kimaki"
KIMAKI_DATA_DIR="$TMPDIR_TEST/kimaki"
PLIST_OUT="$TMPDIR_TEST/kimaki.plist"
bridge_render_launchd com.wp.kimaki > "$PLIST_OUT"
assert_file_contains "launchd includes gateway base URL" "$PLIST_OUT" "<key>OPENAI_BASE_URL</key>"
assert_file_contains "launchd includes gateway key" "$PLIST_OUT" "<key>OPENAI_API_KEY</key>"

echo "==> recursive gateway topologies are rejected in wp-coding-agents"
AI_GATEWAY_ROUTE_PROVIDER="wp-ai-gateway"
if ( ai_gateway_validate_topology ) >/dev/null 2>&1; then
  echo "  FAIL recursive provider should be rejected"
  FAIL=$((FAIL+1))
else
  echo "  ok   recursive provider rejected"
  PASS=$((PASS+1))
fi
AI_GATEWAY_ROUTE_PROVIDER="openai"
AI_GATEWAY_ROUTE_MODEL="opencode:site-default"
if ( ai_gateway_validate_topology ) >/dev/null 2>&1; then
  echo "  FAIL recursive provider-qualified model should be rejected"
  FAIL=$((FAIL+1))
else
  echo "  ok   recursive provider-qualified model rejected"
  PASS=$((PASS+1))
fi
AI_GATEWAY_ROUTE_MODEL="gpt-4o-mini"

echo "==> opencode.json merge uses OpenCode custom provider shape"
DRY_RUN=false
cat > "$SITE_PATH/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-5",
  "provider": {
    "custom": {
      "name": "Custom",
      "models": {}
    }
  }
}
JSON

ai_gateway_configure_opencode
python3 - "$SITE_PATH/opencode.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

provider = data["provider"]["wp-ai-gateway"]
assert provider["npm"] == "@ai-sdk/openai-compatible"
assert provider["env"] == ["OPENAI_API_KEY"]
assert provider["options"]["baseURL"] == "{env:OPENAI_BASE_URL}"
assert "site-default" in provider["models"]
assert data["model"] == "anthropic/claude-sonnet-4-5"
assert "custom" in data["provider"]
PY

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"
  exit 1
fi
echo "OK: $PASS / $PASS assertions passed"
