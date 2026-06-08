#!/bin/bash
# tests/homeboy-codebox-canary.sh — unit test for Homeboy Codebox canary command construction.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
  "$TMP/bin" \
  "$TMP/workspace" \
  "$TMP/agents-api" \
  "$TMP/data-machine" \
  "$TMP/data-machine-code" \
  "$TMP/homeboy-wordpress" \
  "$TMP/provider-openai"

cat > "$TMP/bin/homeboy" <<'SH'
#!/bin/sh
set -eu

write_json_output() {
  file=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then
      file="$2"
      shift 2
      continue
    fi
    shift
  done
  if [ -n "$file" ]; then
    cat > "$file"
  else
    cat >/dev/null
  fi
}

if [ "$1 $2" = "agent-task dispatch" ]; then
  printf '%s\n' "$@" > "$HOMEBOY_CAPTURE_ARGS"
  config=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--provider-config" ]; then
      config="$2"
      break
    fi
    shift
  done
  config="${config#@}"
  cp "$config" "$HOMEBOY_CAPTURE_CONFIG"
  write_json_output "$@" <<'JSON'
{"success":true,"data":{"run_id":"canary-test-run"}}
JSON
  exit 0
fi

if [ "$1 $2" = "agent-task status" ]; then
  write_json_output "$@" <<'JSON'
{"success":true,"data":{"run_id":"canary-test-run","state":"succeeded"}}
JSON
  exit 0
fi

if [ "$1 $2" = "agent-task logs" ]; then
  write_json_output "$@" <<'JSON'
{"success":true,"data":{"events":[{"state":"succeeded","task_id":"canary"}]}}
JSON
  exit 0
fi

if [ "$1 $2" = "agent-task artifacts" ]; then
  write_json_output "$@" <<'JSON'
{"success":true,"data":{"artifacts":[{"kind":"codebox-changed-files","metadata":{"count":0}},{"kind":"codebox-patch","metadata":{"bytes":0}}]}}
JSON
  exit 0
fi

exit 2
SH
chmod +x "$TMP/bin/homeboy"

HOMEBOY_CAPTURE_ARGS="$TMP/args.log"
HOMEBOY_CAPTURE_CONFIG="$TMP/provider-config.json"
export HOMEBOY_CAPTURE_ARGS HOMEBOY_CAPTURE_CONFIG
PATH="$TMP/bin:$PATH"

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL: expected '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -qF -- "$needle" "$file"; then
    echo "FAIL: did not expect '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

assert_json() {
  python3 - "$HOMEBOY_CAPTURE_CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

assert config["agents_api"].endswith("/agents-api")
assert config["runtime_component_paths"]["agent_runtime"].endswith("/data-machine")
assert config["runtime_component_paths"]["agent_runtime_tools"].endswith("/data-machine-code")
assert config["homeboy_extensions"].endswith("/homeboy-wordpress")
assert config["provider"] == "openai"
assert config["model"] == "gpt-4.1-mini"
assert config["max_turns"] == 2
assert config["secret_env"] == ["OPENAI_API_KEY"]
assert config["routing"] == {
    "channel": "canary-channel",
    "thread": "canary-thread",
    "client": "discord",
    "ui": "kimaki",
    "user_required": False,
}
assert config["mounts"] == [
    {
        "source": config["workspace_root"],
        "target": "/workspace",
        "mode": "readonly",
        "metadata": {"kind": "repo-workspace"},
    }
]
assert config["provider_plugin_paths"] and config["provider_plugin_paths"][0].endswith("/provider-openai")
PY
}

OUTPUT="$TMP/output.log"
"$SCRIPT_DIR/scripts/verify-homeboy-codebox-canary.sh" \
  --run \
  --workspace "$TMP/workspace" \
  --repo wp-coding-agents \
  --task-url https://github.com/Extra-Chill/wp-coding-agents/issues/190 \
  --run-id canary-test-run \
  --secret-env OPENAI_API_KEY \
  --agents-api "$TMP/agents-api" \
  --agent-runtime "$TMP/data-machine" \
  --agent-runtime-tools "$TMP/data-machine-code" \
  --homeboy-extensions "$TMP/homeboy-wordpress" \
  --provider-plugin-path "$TMP/provider-openai" \
  --model gpt-4.1-mini \
  --max-turns 2 \
  --channel canary-channel \
  --thread canary-thread \
  > "$OUTPUT"

assert_contains "--secret-env" "$HOMEBOY_CAPTURE_ARGS"
assert_contains "OPENAI_API_KEY" "$HOMEBOY_CAPTURE_ARGS"
assert_contains "--backend" "$HOMEBOY_CAPTURE_ARGS"
assert_contains "codebox" "$HOMEBOY_CAPTURE_ARGS"
assert_not_contains "--channel" "$HOMEBOY_CAPTURE_ARGS"
assert_not_contains "--thread" "$HOMEBOY_CAPTURE_ARGS"
assert_contains "Canary validation passed" "$OUTPUT"
assert_contains "Changed files: 0" "$OUTPUT"
assert_json

if "$SCRIPT_DIR/scripts/verify-homeboy-codebox-canary.sh" \
  --workspace "$TMP/workspace" \
  --repo wp-coding-agents \
  --run-id invalid-secret-test \
  --secret-env 'OPENAI_API_KEY=secret' \
  --agents-api "$TMP/agents-api" \
  --agent-runtime "$TMP/data-machine" \
  --agent-runtime-tools "$TMP/data-machine-code" \
  --homeboy-extensions "$TMP/homeboy-wordpress" \
  --provider-plugin-path "$TMP/provider-openai" \
  > "$TMP/invalid.log" 2>&1; then
  echo "FAIL: invalid secret env value should be rejected"
  exit 1
fi
assert_contains "secret env names must be environment variable names" "$TMP/invalid.log"

echo "OK: Homeboy Codebox canary command construction"
