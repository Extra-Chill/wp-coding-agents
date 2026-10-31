#!/bin/bash
# tests/ai-gateway.sh — regression tests for optional WP AI Gateway integration.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source lib/common.sh
source lib/grants.sh
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
UPDATED_ITEMS=()
mkdir -p "$SITE_PATH/.pi"

echo "==> the gateway opt-in is runtime-agnostic (#774)"
if ai_gateway_enabled; then
  echo "  ok   --with-ai-gateway enables the gateway without an Pi runtime"
  PASS=$((PASS+1))
else
  echo "  FAIL --with-ai-gateway should enable the gateway without an Pi runtime"
  FAIL=$((FAIL+1))
fi
if ( WITH_AI_GATEWAY=false ai_gateway_enabled ); then
  echo "  FAIL gateway must stay off without the flag"
  FAIL=$((FAIL+1))
else
  echo "  ok   gateway stays off without the flag"
  PASS=$((PASS+1))
fi

echo "==> existing gateway env is reused instead of rotated"
cat > "$SITE_PATH/.pi/wp-ai-gateway.env" <<'EOF'
OPENAI_BASE_URL=https://old.example/wp-json/wp-ai-gateway/v1
OPENAI_API_KEY=wpag_existing_secret
EOF

ai_gateway_write_env
assert_file_contains "existing token preserved" "$SITE_PATH/.pi/wp-ai-gateway.env" "OPENAI_API_KEY=wpag_existing_secret"
assert_file_contains "base URL refreshed" "$SITE_PATH/.pi/wp-ai-gateway.env" "OPENAI_BASE_URL=https://example.test/wp-json/wp-ai-gateway/v1"

echo "==> dry-run redacts gateway token material"
DRY_RUN=true
ROTATE_AI_GATEWAY_TOKEN=true
DRY_OUTPUT="$(ai_gateway_write_env 2>&1)"
assert_lacks "dry-run does not print existing token" "$DRY_OUTPUT" "wpag_existing_secret"
assert_lacks "dry-run does not print fake token" "$DRY_OUTPUT" "wpag_"
assert_file_contains "dry-run leaves env token untouched" "$SITE_PATH/.pi/wp-ai-gateway.env" "OPENAI_API_KEY=wpag_existing_secret"

echo "==> the token is reused across upgrades"
DRY_RUN=false
ROTATE_AI_GATEWAY_TOKEN=false
ai_gateway_write_env
ai_gateway_write_env
assert_file_contains "second upgrade run keeps the minted token" "$SITE_PATH/.pi/wp-ai-gateway.env" "OPENAI_API_KEY=wpag_existing_secret"

echo "==> unit/plist dry-run diffs redact secrets"
REDACTED="$(printf '%s\n' '+Environment=OPENAI_API_KEY=wpag_existing_secret' ' <key>ROADIE_BOT_TOKEN</key>' ' <string>discord_secret</string>' | _redact_secret_diff)"
assert_lacks "systemd-style secret redacted" "$REDACTED" "wpag_existing_secret"
assert_lacks "plist-style secret redacted" "$REDACTED" "discord_secret"

echo "==> Kimaki launchd inherits gateway environment"
# shellcheck disable=SC1091
source bridges/roadie.sh
ROADIE_BIN="/usr/bin/kimaki"
ROADIE_DATA_DIR="$TMPDIR_TEST/kimaki"
SERVICE_HOME="$TMPDIR_TEST/home"
PLIST_OUT="$TMPDIR_TEST/kimaki.plist"
bridge_render_launchd com.wp.roadie > "$PLIST_OUT"
assert_file_contains "launchd includes gateway base URL" "$PLIST_OUT" "<key>OPENAI_BASE_URL</key>"
assert_file_contains "launchd includes gateway key" "$PLIST_OUT" "<key>OPENAI_API_KEY</key>"

echo "==> gateway mode points the rendered Pi model at the gateway provider"
assert_eq "resolved Pi model is the gateway model" "wp-ai-gateway/site-default" "$(_roadie_pi_model_value)"
assert_file_contains "launchd carries the gateway Pi model" "$PLIST_OUT" "<key>ROADIE_PI_MODEL</key>"
assert_file_contains "launchd Pi model value is the gateway provider/model" "$PLIST_OUT" "<string>wp-ai-gateway/site-default</string>"
SYSTEMD_ENV_OUT="$(_roadie_append_env_files "$(_roadie_template_env /usr/bin:/bin)")"
printf '%s\n' "$SYSTEMD_ENV_OUT" > "$TMPDIR_TEST/systemd-env"
assert_file_contains "systemd env carries the gateway Pi model" "$TMPDIR_TEST/systemd-env" "Environment=ROADIE_PI_MODEL=wp-ai-gateway/site-default"
assert_file_contains "systemd env references the gateway env file" "$TMPDIR_TEST/systemd-env" "EnvironmentFile=-$SITE_PATH/.pi/wp-ai-gateway.env"

echo "==> an explicit operator model beats the gateway model"
EXPLICIT_MODEL="$(ROADIE_PI_MODEL_EXPLICIT=true ROADIE_PI_MODEL=custom/pinned _roadie_pi_model_value)"
assert_eq "operator-pinned ROADIE_PI_MODEL wins" "custom/pinned" "$EXPLICIT_MODEL"

echo "==> without the gateway Pi stays on the Roadie credential pool"
NO_GATEWAY_OUT="$TMPDIR_TEST/no-gateway"
(
  WITH_AI_GATEWAY=false
  ROADIE_PI_MODEL=roadie/opus
  mkdir -p "$NO_GATEWAY_OUT"
  _roadie_pi_model_value > "$NO_GATEWAY_OUT/model"
  _roadie_append_env_files "$(_roadie_template_env /usr/bin:/bin)" > "$NO_GATEWAY_OUT/systemd-env"
  bridge_render_launchd com.wp.roadie > "$NO_GATEWAY_OUT/plist"
  AI_GATEWAY_PI_AGENT_DIR="$NO_GATEWAY_OUT/pi-agent" ai_gateway_configure_pi
)
assert_eq "pool model passes through unchanged" "roadie/opus" "$(cat "$NO_GATEWAY_OUT/model")"
assert_file_contains "systemd env keeps the roadie/* model" "$NO_GATEWAY_OUT/systemd-env" "Environment=ROADIE_PI_MODEL=roadie/opus"
assert_lacks "systemd env has no gateway env file" "$(cat "$NO_GATEWAY_OUT/systemd-env")" "wp-ai-gateway.env"
assert_lacks "launchd has no gateway base URL" "$(cat "$NO_GATEWAY_OUT/plist")" "OPENAI_BASE_URL"
assert_lacks "launchd model stays on the pool" "$(cat "$NO_GATEWAY_OUT/plist")" "wp-ai-gateway"
if [ -e "$NO_GATEWAY_OUT/pi-agent/models.json" ]; then
  echo "  FAIL no gateway entry should be written without the flag"
  FAIL=$((FAIL+1))
else
  echo "  ok   no gateway models.json entry without the flag"
  PASS=$((PASS+1))
fi

echo "==> Pi models.json gains the gateway provider and keeps Roadie's pool provider"
PI_AGENT_DIR="$ROADIE_DATA_DIR/pi-agent"
mkdir -p "$PI_AGENT_DIR"
cat > "$PI_AGENT_DIR/models.json" <<'JSON'
{
  "providers": {
    "roadie": {
      "baseUrl": "http://127.0.0.1:4097",
      "api": "anthropic-messages",
      "apiKey": "roadie-pool-managed",
      "models": [{"id": "opus"}]
    }
  }
}
JSON
ai_gateway_configure_pi
ai_gateway_configure_pi
python3 - "$PI_AGENT_DIR/models.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

provider = data["providers"]["wp-ai-gateway"]
assert provider["baseUrl"] == "https://example.test/wp-json/wp-ai-gateway/v1", provider
assert provider["api"] == "openai-completions", provider
assert provider["apiKey"] == "$OPENAI_API_KEY", provider
models = {m["id"]: m for m in provider["models"]}
assert list(models) == ["site-default"], models
assert models["site-default"]["cost"] == {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
assert "roadie" in data["providers"], "pool provider must survive the merge"
assert data["providers"]["roadie"]["models"] == [{"id": "opus"}]
PY
echo "  ok   models.json merge is additive, idempotent and token-free"
PASS=$((PASS+1))
assert_lacks "models.json never carries the minted token" "$(cat "$PI_AGENT_DIR/models.json")" "wpag_"

echo "==> the endpoint override (#357) refreshes the Pi provider base URL"
AI_GATEWAY_SITE_URL="https://override.test"
ai_gateway_configure_pi
assert_file_contains "override base URL wins on re-run" "$PI_AGENT_DIR/models.json" '"baseUrl": "https://override.test/wp-json/wp-ai-gateway/v1"'
AI_GATEWAY_SITE_URL=""

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
AI_GATEWAY_ROUTE_MODEL="pi:site-default"
if ( ai_gateway_validate_topology ) >/dev/null 2>&1; then
  echo "  FAIL recursive provider-qualified model should be rejected"
  FAIL=$((FAIL+1))
else
  echo "  ok   recursive provider-qualified model rejected"
  PASS=$((PASS+1))
fi
AI_GATEWAY_ROUTE_MODEL="roadie:opus"
if ( ai_gateway_validate_topology ) >/dev/null 2>&1; then
  echo "  FAIL roadie-qualified route model should be rejected"
  FAIL=$((FAIL+1))
else
  echo "  ok   roadie-qualified route model rejected"
  PASS=$((PASS+1))
fi
AI_GATEWAY_ROUTE_PROVIDER="pi"
AI_GATEWAY_ROUTE_MODEL="gpt-4o-mini"
if ( ai_gateway_validate_topology ) >/dev/null 2>&1; then
  echo "  FAIL pi route provider should be rejected"
  FAIL=$((FAIL+1))
else
  echo "  ok   pi route provider rejected"
  PASS=$((PASS+1))
fi
AI_GATEWAY_ROUTE_PROVIDER="openai"
AI_GATEWAY_ROUTE_MODEL="gpt-4o-mini"

echo "==> pi.json merge uses Pi custom provider shape"
DRY_RUN=false
cat > "$SITE_PATH/pi.json" <<'JSON'
{
  "$schema": "https://pi.ai/config.json",
  "model": "anthropic/claude-sonnet-4-5",
  "provider": {
    "custom": {
      "name": "Custom",
      "models": {}
    }
  }
}
JSON

ai_gateway_configure_pi
python3 - "$SITE_PATH/pi.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

provider = data["provider"]["wp-ai-gateway"]
assert provider["npm"] == "@ai-sdk/openai-compatible"
assert provider["env"] == ["OPENAI_API_KEY"]
assert provider["options"]["baseURL"] == "{env:OPENAI_BASE_URL}"
assert "site-default" in provider["models"]
assert provider["models"]["site-default"]["id"] == "site-default"
assert data["model"] == "anthropic/claude-sonnet-4-5"
assert "custom" in data["provider"]
PY

echo "==> visible gateway identity is separate from the API model"
AI_GATEWAY_PROVIDER_ID="openai"
AI_GATEWAY_MODEL_ID="gpt-5.6-sol"
AI_GATEWAY_API_MODEL_ID="site-default"
cat > "$SITE_PATH/pi.json" <<'JSON'
{
  "$schema": "https://pi.ai/config.json",
  "provider": {
    "openai": {
      "models": {
        "gpt-5.6-sol": {
          "id": "stale-model"
        }
      }
    }
  }
}
JSON

ai_gateway_configure_pi
python3 - "$SITE_PATH/pi.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

model = data["provider"]["openai"]["models"]["gpt-5.6-sol"]
assert data["provider"]["openai"]["npm"] == "@ai-sdk/openai"
assert data["model"] == "openai/gpt-5.6-sol"
assert model["id"] == "site-default"
PY

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"
  exit 1
fi
echo "OK: $PASS / $PASS assertions passed"
