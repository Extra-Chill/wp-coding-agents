#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PACKAGE_ROOT="$TMP/kimaki/dist"
mkdir -p "$PACKAGE_ROOT"

cat > "$TMP/kimaki/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$PACKAGE_ROOT/config.js" <<'JS'
export function setDataDir(value) {
  globalThis.dataDir = value;
}
JS
cat > "$PACKAGE_ROOT/database.js" <<'JS'
import { writeFile } from "node:fs/promises";

export async function initDatabase() {
  globalThis.initialized = true;
}
export async function setBotMode(value) {
  await writeFile(process.env.TEST_RESULT, JSON.stringify({
    operation: "gateway",
    dataDir: globalThis.dataDir,
    initialized: globalThis.initialized,
    value,
  }));
}
export async function setBotToken(appId, token) {
  await writeFile(process.env.TEST_RESULT, JSON.stringify({
    operation: "bot",
    dataDir: globalThis.dataDir,
    initialized: globalThis.initialized,
    appId,
    token,
  }));
}
JS

export KIMAKI_PACKAGE_ROOT="$PACKAGE_ROOT"
export KIMAKI_DATA_DIR="$TMP/state"
export TEST_RESULT="$TMP/result.json"

gateway_token='gateway-client:gateway-secret'
export KIMAKI_BOT_TOKEN="$gateway_token"
output="$(node "$ROOT/scripts/seed-kimaki-credential.mjs" 2>&1)"
[ -z "$output" ] || { echo "FAIL: credential helper produced output"; exit 1; }
python3 - "$TEST_RESULT" "$KIMAKI_DATA_DIR" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data == {
    "operation": "gateway",
    "dataDir": sys.argv[2],
    "initialized": True,
    "value": {
        "appId": "1477605701202481173",
        "clientId": "gateway-client",
        "clientSecret": "gateway-secret",
        "mode": "gateway",
        "proxyUrl": "https://slack-gateway.kimaki.dev",
    },
}
PY

bot_token="$(printf '123456789012345678' | base64 | tr -d '\n').fixture.signature"
export KIMAKI_BOT_TOKEN="$bot_token"
output="$(node "$ROOT/scripts/seed-kimaki-credential.mjs" 2>&1)"
[ -z "$output" ] || { echo "FAIL: credential helper produced output"; exit 1; }
python3 - "$TEST_RESULT" "$KIMAKI_DATA_DIR" "$bot_token" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data == {
    "operation": "bot",
    "dataDir": sys.argv[2],
    "initialized": True,
    "appId": "123456789012345678",
    "token": sys.argv[3],
}
PY

unset KIMAKI_BOT_TOKEN
if node "$ROOT/scripts/seed-kimaki-credential.mjs" >"$TMP/missing.out" 2>"$TMP/missing.err"; then
  echo "FAIL: missing credential was accepted"
  exit 1
fi
grep -F 'KIMAKI_BOT_TOKEN is required' "$TMP/missing.err" >/dev/null

# The external bridge owns invocation; callers only supply the credential and
# selected Kimaki data directory.
mkdir -p "$TMP/runtime/.wp-coding-agents/bin" "$TMP/bin"
cp "$ROOT/scripts/seed-kimaki-credential.mjs" \
  "$TMP/runtime/.wp-coding-agents/bin/kimaki-seed-credential"
chmod +x "$TMP/runtime/.wp-coding-agents/bin/kimaki-seed-credential"
cat > "$TMP/bin/kimaki" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP/bin/kimaki"

export PATH="$TMP/bin:$PATH"
export RUNTIME_PROJECT_ROOT="$TMP/runtime"
export KIMAKI_BOT_TOKEN="$gateway_token"
export EXTERNAL_WORDPRESS=true LOCAL_MODE=true DRY_RUN=false
export SERVICE_HOME="$TMP/home"
UPDATED_ITEMS=()
log() { printf '%s\n' "$*" >> "$TMP/bridge.log"; }
run_cmd() { "$@"; }
error() { printf '%s\n' "$*" >&2; return 1; }
external_wordpress_kimaki_command() { printf '%s' "$TMP/runtime/.wp-coding-agents/bin/kimaki"; }
external_wordpress_kimaki_credential_command() { printf '%s' "$TMP/runtime/.wp-coding-agents/bin/kimaki-seed-credential"; }

# shellcheck disable=SC1091
source "$ROOT/bridges/kimaki.sh"
_kimaki_sync_bin_helpers() { :; }
rm -f "$TEST_RESULT"
bridge_install
python3 - "$TEST_RESULT" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["operation"] == "gateway"
PY
if grep -F "$gateway_token" "$TMP/bridge.log" >/dev/null; then
  echo "FAIL: bridge logged the gateway credential"
  exit 1
fi

echo "PASS: tests/kimaki-credential-seeding.sh"
