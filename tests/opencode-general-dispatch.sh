#!/bin/bash
# Live OpenCode contract for bounded native general-subagent dispatch.
set -eu

# A managed parent session exports its own server/config identity. The child
# process must discover only this test's temporary project configuration.
unset OPENCODE OPENCODE_CONFIG OPENCODE_PID OPENCODE_PORT OPENCODE_PRINT_LOGS OPENCODE_LOG_LEVEL
unset OPENCODE_EXPERIMENTAL_WORKSPACES OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS
unset KIMAKI KIMAKI_DATA_DIR KIMAKI_CONFIG_DIR KIMAKI_OPENCODE_PROCESS KIMAKI_THREAD_ID

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
SITE="$TMP/site"
WORKSPACE="$TMP/workspace"
PORT_FILE="$TMP/port"
STATE_FILE="$TMP/state.json"
OUTPUT_FILE="$TMP/output.jsonl"
mkdir -p "$SITE/wp-content/plugins/vendor" "$SITE/.opencode" "$WORKSPACE" "$TMP/home" "$TMP/config" "$TMP/data" "$TMP/cache" "$TMP/state"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data" XDG_CACHE_HOME="$TMP/cache" XDG_STATE_HOME="$TMP/state"
printf '%s\n' 'installed source' > "$SITE/wp-content/plugins/vendor/plugin.php"
printf '%s\n' '# Coordinator' > "$TMP/SOUL.md"

python3 - "$PORT_FILE" "$STATE_FILE" "$SITE" <<'PY' &
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, state_file, site = sys.argv[1:]
condition = threading.Condition()
children = []
child_directories = []

def response(content=None, tool_calls=None, finish="stop"):
    message = {"role": "assistant", "content": content}
    if tool_calls is not None:
        message["tool_calls"] = tool_calls
    return {
        "id": "chatcmpl-fixture", "object": "chat.completion", "created": int(time.time()), "model": "fixture",
        "choices": [{"index": 0, "message": message, "finish_reason": finish}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        encoded = json.dumps(request.get("messages", []))
        if any(message.get("role") == "tool" for message in request.get("messages", [])):
            body = response("PARENT_COMPLETE")
        elif "ALPHA_ONLY" in encoded or "BETA_ONLY" in encoded:
            marker = "ALPHA_ONLY" if "ALPHA_ONLY" in encoded else "BETA_ONLY"
            with condition:
                children.append(marker)
                child_directories.append(site in encoded)
                condition.notify_all()
                concurrent = condition.wait_for(lambda: len(children) == 2, timeout=10)
                with open(state_file, "w", encoding="utf-8") as handle:
                    json.dump({"children": sorted(children), "concurrent": concurrent, "explicit_directory": all(child_directories)}, handle)
            body = response(marker)
        else:
            calls = []
            for index, marker in enumerate(("ALPHA_ONLY", "BETA_ONLY"), 1):
                arguments = json.dumps({
                    "description": f"fixture task {index}",
                    "prompt": f"Complete this independent coding fixture. Return exactly {marker}.",
                    "subagent_type": "general",
                })
                calls.append({"id": f"call_{index}", "type": "function", "function": {"name": "task", "arguments": arguments}})
            body = response(tool_calls=calls, finish="tool_calls")
        if request.get("stream"):
            message = body["choices"][0]["message"]
            delta = {"role": "assistant"}
            if message.get("tool_calls") is not None:
                delta["tool_calls"] = message["tool_calls"]
            else:
                delta["content"] = message.get("content") or ""
            chunks = [
                {"id": body["id"], "object": "chat.completion.chunk", "created": body["created"], "model": body["model"],
                 "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                {"id": body["id"], "object": "chat.completion.chunk", "created": body["created"], "model": body["model"],
                 "choices": [{"index": 0, "delta": {}, "finish_reason": body["choices"][0]["finish_reason"]}]},
            ]
            payload = b"".join(b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks) + b"data: [DONE]\n\n"
            content_type = "text/event-stream"
        else:
            payload = json.dumps(body).encode()
            content_type = "application/json"
        self.send_response(200)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 400); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.05
done
[ -s "$PORT_FILE" ] || { echo "FAIL: fixture provider did not start"; exit 1; }
PORT="$(cat "$PORT_FILE")"

python3 - "$SITE/opencode.json" "$WORKSPACE" "$PORT" <<'PY'
import json, sys
path, workspace, port = sys.argv[1:]
json.dump({
    "$schema": "https://opencode.ai/config.json",
    "model": "fixture/test",
    "provider": {"fixture": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Fixture",
        "options": {"baseURL": f"http://127.0.0.1:{port}/v1", "apiKey": "fixture"},
        "models": {"test": {"name": "Fixture"}},
    }},
    "permission": {
        "external_directory": {f"{workspace}/**": "allow"},
        "edit": {"wp-content/plugins/**": "deny"},
    },
}, open(path, "w"), indent=2)
PY

python3 - "$TMP/graph.json" "$TMP/SOUL.md" <<'PY'
import json, sys
path, soul = sys.argv[1:]
json.dump({
    "success": True,
    "coordinator": "coordinator",
    "nodes": [{
        "slug": "coordinator", "description": "Routes work", "subagents": [], "model": "",
        "sources": {"instructions": {"SOUL.md": soul}, "skills": {}, "references": {}},
        "tool_policy": {"default": "deny", "allow": []}, "skill_policy": {"paths": []},
    }],
}, open(path, "w"))
PY

SITE_PATH="$SITE"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/opencode-subagents.sh"
warn() { printf '%s\n' "$*" >&2; }
opencode_general_dispatch_supported
python3 "$SCRIPT_DIR/lib/project-opencode-subagents.py" "$TMP/graph.json" "$SITE"

python3 - "$SITE/opencode.json" "$WORKSPACE" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
assert config["permission"]["task"] == {"*": "deny", "general": "allow"}
assert config["permission"]["external_directory"] == {f"{sys.argv[2]}/**": "allow"}
assert config["permission"]["edit"] == {"wp-content/plugins/**": "deny"}
PY

(cd "$SITE" && opencode agent list --pure) > "$TMP/agents.txt"
python3 - "$TMP/agents.txt" "$WORKSPACE" <<'PY'
import re, sys
text, workspace = open(sys.argv[1]).read(), sys.argv[2]
parts = re.split(r'^(\w+) \((?:primary|subagent)\)\n', text, flags=re.M)
sections = dict(zip(parts[1::2], parts[2::2]))
assert "build" in sections and "general" in sections, text
build, general = sections["build"], sections["general"]
assert '"permission": "task"' in build and '"pattern": "general"' in build and '"action": "allow"' in build
assert workspace in general and 'wp-content/plugins/**' in general
PY

python3 - "$SITE" "$OUTPUT_FILE" <<'PY'
import os, pathlib, subprocess, sys
site, output = sys.argv[1:]
try:
    result = subprocess.run(
        ["opencode", "run", "--pure", "--dir", site, "--format", "json", "--model", "fixture/test", "--agent", "build",
         "Dispatch both independent fixture tasks concurrently with the task tool."],
        cwd=site, text=True, capture_output=True, timeout=45,
    )
except subprocess.TimeoutExpired as error:
    sys.stderr.write((error.stderr or b"").decode() if isinstance(error.stderr, bytes) else (error.stderr or ""))
    sys.stderr.write((error.stdout or b"").decode() if isinstance(error.stdout, bytes) else (error.stdout or ""))
    raise
open(output, "w", encoding="utf-8").write(result.stdout)
if result.returncode:
    sys.stderr.write(f"opencode run exited {result.returncode}\n")
    sys.stderr.write(result.stderr)
    sys.stderr.write(result.stdout)
    for path in pathlib.Path(os.environ["XDG_DATA_HOME"]).glob("**/*.log"):
        sys.stderr.write(f"\n== {path} ==\n{path.read_text(errors='replace')}")
    raise SystemExit(result.returncode)
PY

[ -f "$STATE_FILE" ] || { printf '%s\n' 'FAIL: fixture provider received no child requests'; cat "$OUTPUT_FILE"; exit 1; }
python3 - "$STATE_FILE" "$OUTPUT_FILE" <<'PY'
import json, re, sys
state = json.load(open(sys.argv[1]))
assert state == {"children": ["ALPHA_ONLY", "BETA_ONLY"], "concurrent": True, "explicit_directory": True}, state
strings = []
tasks = []
def collect(value):
    if isinstance(value, str): strings.append(value)
    elif isinstance(value, list):
        for item in value: collect(item)
    elif isinstance(value, dict):
        for item in value.values(): collect(item)
for line in open(sys.argv[2]):
    event = json.loads(line)
    collect(event)
    part = event.get("part", {})
    if event.get("type") == "tool_use" and part.get("tool") == "task":
        tasks.append(part)
text = "\n".join(strings)
sessions = re.findall(r'<task id="([^"]+)" state="completed">', text)
assert len(set(sessions)) == 2, text
assert len(tasks) == 2 and all(task["state"]["status"] == "completed" for task in tasks), tasks
metadata = [task["state"]["metadata"] for task in tasks]
assert {item["sessionId"] for item in metadata} == set(sessions), metadata
assert all(item["model"] == {"providerID": "fixture", "modelID": "test"} for item in metadata), metadata
assert "ALPHA_ONLY" in text and "BETA_ONLY" in text and "PARENT_COMPLETE" in text
PY

printf '%s\n' 'opencode-general-dispatch: two native general tasks completed concurrently with distinct sessions'
