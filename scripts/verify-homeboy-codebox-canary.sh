#!/bin/bash
# Opt-in Homeboy Codebox fleet canary for wp-coding-agents installs.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

RUN=false
WORKSPACE="${HOMEBOY_CANARY_WORKSPACE:-}"
REPO="${HOMEBOY_CANARY_REPO:-wp-coding-agents}"
TASK_URL="${HOMEBOY_CANARY_TASK_URL:-https://github.com/Extra-Chill/wp-coding-agents/issues/190}"
RUN_ID="${HOMEBOY_CANARY_RUN_ID:-homeboy-codebox-canary-$(date -u +%Y%m%d-%H%M%S)}"
MODEL="${HOMEBOY_CANARY_MODEL:-}"
PROVIDER="${HOMEBOY_CANARY_PROVIDER:-openai}"
MAX_TURNS="${HOMEBOY_CANARY_MAX_TURNS:-4}"
CHANNEL="${HOMEBOY_CANARY_CHANNEL:-}"
THREAD="${HOMEBOY_CANARY_THREAD:-}"
ARTIFACT_ROOT="${HOMEBOY_CANARY_ARTIFACT_ROOT:-}"
EVIDENCE_DIR="${HOMEBOY_CANARY_EVIDENCE_DIR:-}"
AGENTS_API="${HOMEBOY_CANARY_AGENTS_API:-}"
AGENT_RUNTIME="${HOMEBOY_CANARY_AGENT_RUNTIME:-}"
AGENT_RUNTIME_TOOLS="${HOMEBOY_CANARY_AGENT_RUNTIME_TOOLS:-}"
HOMEBOY_EXTENSIONS="${HOMEBOY_CANARY_HOMEBOY_EXTENSIONS:-$HOME/.config/homeboy/extensions/wordpress}"
SECRET_ENVS=()
PROVIDER_PLUGIN_PATHS=()

if [ -n "${HOMEBOY_CANARY_SECRET_ENV:-}" ]; then
  IFS=',' read -r -a SECRET_ENVS <<< "${HOMEBOY_CANARY_SECRET_ENV}"
fi

if [ -n "${HOMEBOY_CANARY_PROVIDER_PLUGIN_PATHS:-}" ]; then
  IFS=':' read -r -a PROVIDER_PLUGIN_PATHS <<< "${HOMEBOY_CANARY_PROVIDER_PLUGIN_PATHS}"
fi

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [--run] --workspace <path> --secret-env <ENV_NAME> \\
  --agents-api <path> --agent-runtime <path> --agent-runtime-tools <path> \\
  --provider-plugin-path <path> [options]

Prints a safe Homeboy Codebox canary command by default. Use --run to execute
the canary and validate terminal status, logs, changed-files, and patch evidence.

Options:
  --run                         Execute the canary. Default only prints command.
  --workspace <path>            Existing repo checkout/worktree mounted read-only at /workspace.
  --repo <slug>                 Repo slug for Homeboy metadata. Default: wp-coding-agents.
  --task-url <url>              Tracker URL. Default: issue #190.
  --run-id <id>                 Durable Homeboy run id. Default: generated timestamp id.
  --provider <id>               Provider id in Codebox config. Default: openai.
  --model <id>                  Optional model override.
  --max-turns <n>               Low turn cap for the read-only canary. Default: 4.
  --secret-env <ENV_NAME>       Provider secret env var name to hydrate. Repeatable.
  --agents-api <path>           Bundled Agents API path.
  --agent-runtime <path>        Agent runtime component path.
  --agent-runtime-tools <path>  Runtime tools component path.
  --provider-plugin-path <path> Provider plugin path. Repeatable.
  --homeboy-extensions <path>   Homeboy WordPress extension path.
  --channel <id>                Optional Discord channel id for provider routing.
  --thread <id>                 Optional Discord thread id for provider routing.
  --artifact-root <path>        Optional artifact copy root for Homeboy.
  --evidence-dir <path>         Optional directory for local validator JSON output.
  --help                        Show this help.

Secret values are never printed. Pass secret environment variable names only.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN=true
      shift
      ;;
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --task-url)
      TASK_URL="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --provider)
      PROVIDER="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --max-turns)
      MAX_TURNS="$2"
      shift 2
      ;;
    --secret-env)
      SECRET_ENVS+=("$2")
      shift 2
      ;;
    --agents-api)
      AGENTS_API="$2"
      shift 2
      ;;
    --agent-runtime)
      AGENT_RUNTIME="$2"
      shift 2
      ;;
    --agent-runtime-tools)
      AGENT_RUNTIME_TOOLS="$2"
      shift 2
      ;;
    --provider-plugin-path)
      PROVIDER_PLUGIN_PATHS+=("$2")
      shift 2
      ;;
    --homeboy-extensions)
      HOMEBOY_EXTENSIONS="$2"
      shift 2
      ;;
    --channel)
      CHANNEL="$2"
      shift 2
      ;;
    --thread)
      THREAD="$2"
      shift 2
      ;;
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --evidence-dir)
      EVIDENCE_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_dir() {
  local label="$1" path="$2"
  [ -n "$path" ] || fail "$label is required"
  [ -d "$path" ] || fail "$label does not exist or is not a directory: $path"
}

validate_env_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*|[0-9]*)
      fail "secret env names must be environment variable names, got: $1"
      ;;
  esac
}

[ -n "$WORKSPACE" ] || fail "--workspace is required"
[ -d "$WORKSPACE" ] || fail "workspace does not exist or is not a directory: $WORKSPACE"
[ -n "$REPO" ] || fail "--repo must not be empty"
[ -n "$RUN_ID" ] || fail "--run-id must not be empty"
[[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || fail "--max-turns must be a positive integer"
[ "$MAX_TURNS" -gt 0 ] || fail "--max-turns must be a positive integer"
[ ${#SECRET_ENVS[@]} -gt 0 ] || fail "at least one --secret-env name is required so provider auth is explicit"

for secret_env in "${SECRET_ENVS[@]}"; do
  validate_env_name "$secret_env"
done

require_dir "--agents-api" "$AGENTS_API"
require_dir "--agent-runtime" "$AGENT_RUNTIME"
require_dir "--agent-runtime-tools" "$AGENT_RUNTIME_TOOLS"
require_dir "--homeboy-extensions" "$HOMEBOY_EXTENSIONS"
[ ${#PROVIDER_PLUGIN_PATHS[@]} -gt 0 ] || fail "at least one --provider-plugin-path is required"
for provider_plugin_path in "${PROVIDER_PLUGIN_PATHS[@]}"; do
  require_dir "--provider-plugin-path" "$provider_plugin_path"
done

if [ "$RUN" = true ] && ! command -v homeboy >/dev/null 2>&1; then
  fail "homeboy command was not found"
fi

if [ -n "$EVIDENCE_DIR" ]; then
  TMP_DIR="$EVIDENCE_DIR"
  mkdir -p "$TMP_DIR"
else
  TMP_DIR="$(mktemp -d)"
fi

if [ "$RUN" != true ] && [ -z "$EVIDENCE_DIR" ]; then
  trap 'rm -rf "$TMP_DIR"' EXIT
fi

CONFIG_FILE="$TMP_DIR/provider-config.json"
DISPATCH_OUT="$TMP_DIR/dispatch.json"
DISPATCH_STDOUT="$TMP_DIR/dispatch-output.json"
STATUS_OUT="$TMP_DIR/status.json"
LOGS_OUT="$TMP_DIR/logs.json"
ARTIFACTS_OUT="$TMP_DIR/artifacts.json"

export CANARY_WORKSPACE="$WORKSPACE"
export CANARY_REPO="$REPO"
export CANARY_PROVIDER="$PROVIDER"
export CANARY_MODEL="$MODEL"
export CANARY_MAX_TURNS="$MAX_TURNS"
export CANARY_AGENTS_API="$AGENTS_API"
export CANARY_AGENT_RUNTIME="$AGENT_RUNTIME"
export CANARY_AGENT_RUNTIME_TOOLS="$AGENT_RUNTIME_TOOLS"
export CANARY_HOMEBOY_EXTENSIONS="$HOMEBOY_EXTENSIONS"
export CANARY_CHANNEL="$CHANNEL"
export CANARY_THREAD="$THREAD"
export CANARY_PROVIDER_PLUGIN_PATHS="$(printf '%s\n' "${PROVIDER_PLUGIN_PATHS[@]}")"
export CANARY_SECRET_ENVS="$(printf '%s\n' "${SECRET_ENVS[@]}")"

python3 - "$CONFIG_FILE" <<'PY'
import json
import os
import sys

provider_plugin_paths = [
    path for path in os.environ["CANARY_PROVIDER_PLUGIN_PATHS"].splitlines() if path
]
secret_env = [name for name in os.environ["CANARY_SECRET_ENVS"].splitlines() if name]

config = {
    "agents_api": os.environ["CANARY_AGENTS_API"],
    "homeboy_extensions": os.environ["CANARY_HOMEBOY_EXTENSIONS"],
    "max_turns": int(os.environ["CANARY_MAX_TURNS"]),
    "mounts": [
        {
            "source": os.environ["CANARY_WORKSPACE"],
            "target": "/workspace",
            "mode": "readonly",
            "metadata": {"kind": "repo-workspace"},
        }
    ],
    "provider": os.environ["CANARY_PROVIDER"],
    "provider_plugin_paths": provider_plugin_paths,
    "repo": os.environ["CANARY_REPO"],
    "runtime_component_paths": {
        "agent_runtime": os.environ["CANARY_AGENT_RUNTIME"],
        "agent_runtime_tools": os.environ["CANARY_AGENT_RUNTIME_TOOLS"],
    },
    "task_kind": "repo-cooking-canary",
    "secret_env": secret_env,
    "workspace_root": os.environ["CANARY_WORKSPACE"],
}

if os.environ.get("CANARY_MODEL"):
    config["model"] = os.environ["CANARY_MODEL"]

routing = {}
if os.environ.get("CANARY_CHANNEL"):
    routing["channel"] = os.environ["CANARY_CHANNEL"]
if os.environ.get("CANARY_THREAD"):
    routing["thread"] = os.environ["CANARY_THREAD"]
if routing:
    routing.update({"client": "discord", "ui": "kimaki", "user_required": False})
    config["routing"] = routing

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY

PROMPT="Read-only Homeboy Codebox canary for wp-coding-agents. Inspect /workspace only. Do not edit files, do not commit, do not push, and do not create PRs. Return current directory, git branch/status summary, one repo purpose fact, and whether any files changed."

COMMAND=(
  homeboy agent-task dispatch
  --run-id "$RUN_ID"
  --repo "$REPO"
  --cwd "$WORKSPACE"
  --backend codebox
  --concurrency 1
  --attempts 1
  --task-url "$TASK_URL"
  --provider-config "@$CONFIG_FILE"
  --prompt "$PROMPT"
)

for secret_env in "${SECRET_ENVS[@]}"; do
  COMMAND+=(--secret-env "$secret_env")
done

if [ -n "$MODEL" ]; then
  COMMAND+=(--model "$MODEL")
fi

if [ -n "$ARTIFACT_ROOT" ]; then
  COMMAND+=(--artifact-root "$ARTIFACT_ROOT")
fi

print_command() {
  printf 'Provider config: %s\n' "$CONFIG_FILE"
  printf 'Canary command:'
  printf ' %q' "${COMMAND[@]}"
  printf '\n'
}

if [ "$RUN" != true ]; then
  print_command
  echo "Dry run only. Re-run with --run to execute the model-backed Codebox canary."
  exit 0
fi

echo "Dispatching Homeboy Codebox canary run: $RUN_ID"
"${COMMAND[@]}" --output "$DISPATCH_OUT" > "$DISPATCH_STDOUT"

homeboy agent-task status "$RUN_ID" --output "$STATUS_OUT" >/dev/null
homeboy agent-task logs "$RUN_ID" --output "$LOGS_OUT" >/dev/null
homeboy agent-task artifacts "$RUN_ID" --output "$ARTIFACTS_OUT" >/dev/null

python3 - "$STATUS_OUT" "$LOGS_OUT" "$ARTIFACTS_OUT" <<'PY'
import json
import sys

status_path, logs_path, artifacts_path = sys.argv[1:]

with open(status_path, encoding="utf-8") as handle:
    status_payload = json.load(handle)
with open(logs_path, encoding="utf-8") as handle:
    logs_payload = json.load(handle)
with open(artifacts_path, encoding="utf-8") as handle:
    artifacts_payload = json.load(handle)

status = status_payload.get("data", {})
if not status_payload.get("success") or status.get("state") != "succeeded":
    raise SystemExit(f"canary did not reach succeeded state: {status.get('state')!r}")

events = logs_payload.get("data", {}).get("events", [])
if not any(event.get("state") == "succeeded" for event in events):
    raise SystemExit("canary logs do not include a succeeded event")

artifacts = artifacts_payload.get("data", {}).get("artifacts", [])
changed = next((item for item in artifacts if item.get("kind") == "codebox-changed-files"), None)
patch = next((item for item in artifacts if item.get("kind") == "codebox-patch"), None)
if changed is None:
    raise SystemExit("missing codebox-changed-files artifact")
if patch is None:
    raise SystemExit("missing codebox-patch artifact")

changed_count = changed.get("metadata", {}).get("count")
if changed_count != 0:
    raise SystemExit(f"read-only canary changed files: {changed_count}")

patch_bytes = patch.get("metadata", {}).get("bytes", patch.get("size_bytes"))
if patch_bytes != 0:
    raise SystemExit(f"read-only canary produced a non-empty patch: {patch_bytes} bytes")

print("Canary validation passed")
print(f"Run ID: {status.get('run_id')}")
print(f"State: {status.get('state')}")
print("Changed files: 0")
print("Patch bytes: 0")
PY

echo "Status evidence: $STATUS_OUT"
echo "Log evidence: $LOGS_OUT"
echo "Artifact evidence: $ARTIFACTS_OUT"
echo "Dispatch output: $DISPATCH_STDOUT"
