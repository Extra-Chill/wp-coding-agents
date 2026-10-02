#!/bin/bash
# Remove only files and OpenCode values recorded by the retired v2 projector.
opencode_subagents_retire() {
  local site_path="${1:-${SITE_PATH:-}}"
  [ -n "$site_path" ] || return 0
  python3 - "$site_path" <<'PY'
import json
import os
import sys
import tempfile

site = sys.argv[1]
root = os.path.join(site, ".opencode")
manifest_path = os.path.join(root, ".wp-coding-agents-subagents.json")
if not os.path.lexists(manifest_path):
    raise SystemExit(0)
if os.path.islink(manifest_path):
    print("OpenCode subagent retirement skipped: refusing symlink manifest", file=sys.stderr)
    raise SystemExit(1)
try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except (OSError, ValueError) as error:
    print(f"OpenCode subagent retirement skipped: invalid manifest: {error}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(manifest, dict) or manifest.get("sentinel") != "wp-coding-agents-opencode-subagents-v2":
    print("OpenCode subagent retirement skipped: unrecognized manifest sentinel", file=sys.stderr)
    raise SystemExit(0)

artifacts = manifest.get("artifacts", [])
if not isinstance(artifacts, list):
    print("OpenCode subagent retirement skipped: invalid artifact list", file=sys.stderr)
    raise SystemExit(1)
paths = []
for relative in artifacts:
    if not isinstance(relative, str) or not relative.startswith(("agents/", "skills/")):
        print(f"OpenCode subagent retirement skipped: refusing artifact path {relative!r}", file=sys.stderr)
        raise SystemExit(1)
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        print(f"OpenCode subagent retirement skipped: refusing artifact path {relative!r}", file=sys.stderr)
        raise SystemExit(1)
    path = os.path.join(root, *parts)
    current = root
    unsafe = os.path.islink(root)
    for part in parts:
        current = os.path.join(current, part)
        unsafe = unsafe or os.path.islink(current)
    if unsafe:
        print(f"OpenCode subagent retirement skipped: refusing symlink artifact {relative!r}", file=sys.stderr)
        raise SystemExit(1)
    paths.append(path)

config_path = os.path.join(site, "opencode.json")
data = None
config_changed = False
if os.path.isfile(config_path):
    if os.path.islink(config_path):
        print("OpenCode subagent retirement skipped: refusing symlink opencode.json", file=sys.stderr)
        raise SystemExit(1)
    try:
        with open(config_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"OpenCode subagent retirement skipped: invalid opencode.json: {error}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(data, dict):
        print("OpenCode subagent retirement skipped: opencode.json root is not an object", file=sys.stderr)
        raise SystemExit(1)
    permission = data.get("permission")
    if isinstance(permission, dict):
        removed_permission = False
        for key, manifest_key in (("task", "task_permission"), ("skill", "skill_permission")):
            if manifest_key in manifest and permission.get(key) == manifest[manifest_key]:
                permission.pop(key)
                config_changed = True
                removed_permission = True
        if removed_permission and not permission:
            data.pop("permission")
    agent = data.get("agent")
    if isinstance(agent, dict) and "general_agent" in manifest and agent.get("general") == manifest["general_agent"]:
        agent.pop("general")
        config_changed = True
        if not agent:
            data.pop("agent")

if data is not None and config_changed:
    directory = os.path.dirname(config_path)
    fd, temporary = tempfile.mkstemp(prefix=".opencode.json.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, os.stat(config_path).st_mode & 0o7777)
        os.replace(temporary, config_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

for path in paths:
    if os.path.isfile(path):
        os.unlink(path)
os.unlink(manifest_path)
PY
}
