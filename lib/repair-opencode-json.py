#!/usr/bin/env python3
"""
repair-opencode-json.py — Detect and optionally repair drift in an existing
opencode.json against what the current wp-coding-agents setup would produce
for the detected (RUNTIME, CHAT_BRIDGE). Data Machine is always installed.

Checks two independent drift vectors:
  1. `plugin` array — matches what setup would produce for the detected
     (RUNTIME, CHAT_BRIDGE) combo.
  2. `agent.build.prompt` / `agent.plan.prompt` — legacy format that breaks
     Anthropic Claude Max OAuth (see wp-coding-agents#60). Migrated to a
     top-level `instructions` array that preserves the canonical system prompt
     opening.

Exit codes:
  0 — no drift; file is already correct
  1 — drift detected (or repair applied if --apply)
  2 — usage / IO error

Output (stdout): JSON diagnostic object. Examples:

  {"status":"ok","plugins":[...],"prompt_migration":"ok"}
  {"status":"drift","missing":[...],"unexpected":[...],...,"prompt_migration":"needed"}
  {"status":"repaired","before":[...],"after":[...],"backup":"/path/to/backup","prompt_migration":"migrated"}

CLI usage:
  repair-opencode-json.py --file <path> \
    --runtime <opencode|claude-code|studio-code> \
    --chat-bridge <kimaki|cc-connect|telegram|none> \
    [--kimaki-plugins-dir <path>] \
    [--apply] \
    [--backup-suffix <timestamp>]

Only --apply writes to disk. Without it, the tool is a pure diagnostic.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from typing import List


def expected_plugins(
    runtime: str,
    chat_bridge: str,
    kimaki_plugins_dir: str,
) -> List[str]:
    """Return the `plugin` array wp-coding-agents setup would produce today.

    Mirrors the logic in runtimes/opencode.sh. Keep in sync when that file
    changes. Order matters — setup.sh writes them in this order.
    """
    plugins: List[str] = []

    if runtime != "opencode":
        # Non-opencode runtimes don't use the opencode.json plugin array.
        # Claude Code / Studio Code have their own config. Return empty so
        # "drift" comparisons on those runtimes are no-ops.
        return plugins

    # opencode-claude-auth: only when kimaki is NOT the chat bridge.
    # Kimaki v0.6.0+ ships a built-in AnthropicAuthPlugin that supersedes it;
    # loading both causes them to compete for the `anthropic` auth provider.
    # See wp-coding-agents#51.
    if chat_bridge != "kimaki":
        plugins.append("opencode-claude-auth@latest")

    # DM context filter + agent sync: only when the bridge is Kimaki, since
    # these plugins rewrite Kimaki-specific prompts.
    if chat_bridge == "kimaki":
        plugins.append(f"{kimaki_plugins_dir}/dm-context-filter.ts")
        plugins.append(f"{kimaki_plugins_dir}/dm-agent-sync.ts")

    return plugins


def diff_plugins(current: List[str], expected: List[str]) -> dict:
    """Compute missing and unexpected entries.

    `missing`    = in expected but not current
    `unexpected` = in current but not expected (likely to remove)

    We match by exact string equality. Order differences alone are NOT
    flagged as drift — opencode loads plugins regardless of array order.
    """
    current_set = set(current)
    expected_set = set(expected)
    return {
        "missing": [p for p in expected if p not in current_set],
        "unexpected": [p for p in current if p not in expected_set],
    }


def repair(
    data: dict, expected: List[str], preserve_extras: bool = False
) -> List[str]:
    """Return the repaired `plugin` array.

    Default behaviour: replace `plugin` with exactly `expected`. This removes
    stale entries (like `opencode-claude-auth@latest` on kimaki installs).

    With preserve_extras=True: add missing entries but keep unexpected ones.
    Not currently exposed via CLI — here for future use.
    """
    if preserve_extras:
        current: List[str] = list(data.get("plugin", []))
        for p in expected:
            if p not in current:
                current.append(p)
        return current
    return list(expected)


def parse_file_includes(prompt: str) -> List[str]:
    """Extract ``{file:./path}`` references from a prompt string.

    Returns relative paths (without the ``./`` prefix) in order of appearance.
    Skips ``{file:./AGENTS.md}`` — AGENTS.md is auto-discovered by opencode
    and should not go in the ``instructions`` array.
    """
    import re

    paths: List[str] = []
    for match in re.finditer(r"\{file:\./([^}]+)\}", prompt):
        rel = match.group(1)
        if rel == "AGENTS.md":
            continue
        paths.append(rel)
    return paths


def check_prompt_migration(data: dict) -> dict:
    """Check whether ``agent.build.prompt`` / ``agent.plan.prompt`` need migration.

    Returns a dict with keys:
      status: "ok" | "needed"
      details: human-readable description (when needed)
      instructions: the ``instructions`` array that should be written
    """
    agent = data.get("agent", {})
    build_prompt = agent.get("build", {}).get("prompt", "")
    plan_prompt = agent.get("plan", {}).get("prompt", "")

    if not build_prompt and not plan_prompt:
        # Already on new format or never had prompts.
        return {"status": "ok", "instructions": list(data.get("instructions", []))}

    # Extract file paths from whichever prompt has them (prefer build).
    source = build_prompt or plan_prompt
    paths = parse_file_includes(source)

    return {
        "status": "needed",
        "details": (
            "agent.build.prompt/agent.plan.prompt detected — "
            "must migrate to top-level 'instructions' array to fix "
            "Anthropic Claude Max OAuth (see wp-coding-agents#60)"
        ),
        "instructions": [f"./{p}" for p in paths],
    }


def apply_prompt_migration(data: dict) -> dict:
    """Migrate ``agent.build.prompt`` → ``instructions`` in *data* (in-place).

    - Removes ``prompt`` keys from ``agent.build`` and ``agent.plan``.
    - Sets top-level ``instructions`` array (preserving any existing entries
      that are not duplicates of the migrated paths).
    - Returns the migration result dict from ``check_prompt_migration``.
    """
    result = check_prompt_migration(data)
    if result["status"] != "needed":
        return result

    new_instructions = result["instructions"]

    # Remove prompt keys.
    agent = data.get("agent", {})
    for sub in ("build", "plan"):
        agent.get(sub, {}).pop("prompt", None)
    # Clean up empty dicts.
    for sub in ("build", "plan"):
        if sub in agent and isinstance(agent[sub], dict) and not agent[sub]:
            pass  # keep mode/model keys

    # Merge with any existing instructions, preserving user-added entries.
    existing = set(data.get("instructions", []))
    merged = list(data.get("instructions", []))
    for p in new_instructions:
        if p not in existing:
            merged.append(p)
    data["instructions"] = merged

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, help="Path to opencode.json")
    parser.add_argument(
        "--runtime",
        required=True,
        choices=["opencode", "claude-code", "studio-code"],
    )
    parser.add_argument(
        "--chat-bridge",
        required=True,
        choices=["kimaki", "cc-connect", "telegram", "none"],
    )
    parser.add_argument(
        "--kimaki-plugins-dir",
        default="/opt/kimaki-config/plugins",
        help="Directory where DM plugins live (VPS default: /opt/kimaki-config/plugins)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write repaired config to disk (with .backup.<suffix> alongside)",
    )
    parser.add_argument(
        "--backup-suffix",
        default="",
        help="Suffix for backup file (default: current timestamp)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.file):
        print(
            json.dumps({"status": "error", "message": f"file not found: {args.file}"})
        )
        return 2

    try:
        with open(args.file, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        print(
            json.dumps(
                {"status": "error", "message": f"invalid JSON: {exc}"}
            )
        )
        return 2

    # --- Prompt migration check (runs for all runtimes with opencode.json) ---
    prompt_result = check_prompt_migration(data)

    # --- Plugin array check ---
    expected = expected_plugins(
        runtime=args.runtime,
        chat_bridge=args.chat_bridge,
        kimaki_plugins_dir=args.kimaki_plugins_dir.rstrip("/"),
    )

    current: List[str] = list(data.get("plugin", []))

    # Claude Code / Studio Code: no plugin array concept here. Report ok
    # if current is empty or absent; otherwise let user know we skipped.
    plugin_skipped = False
    if args.runtime != "opencode":
        plugin_skipped = True
        if prompt_result["status"] == "ok":
            print(
                json.dumps(
                    {
                        "status": "ok",
                        "plugins": current,
                        "prompt_migration": "ok",
                    }
                )
            )
            return 0

    diff = diff_plugins(current, expected)
    has_plugin_drift = bool(diff["missing"] or diff["unexpected"])
    has_prompt_drift = prompt_result["status"] == "needed"
    has_any_drift = has_plugin_drift or has_prompt_drift

    if not has_any_drift:
        result: dict = {"status": "ok", "plugins": current, "prompt_migration": "ok"}
        if plugin_skipped:
            result["plugins_skipped"] = f"runtime {args.runtime} does not use opencode.json plugin array"
        print(json.dumps(result))
        return 0

    if not args.apply:
        result = {
            "status": "drift",
            "current": current,
            "expected": expected,
            "prompt_migration": prompt_result["status"],
        }
        if has_plugin_drift:
            result["missing"] = diff["missing"]
            result["unexpected"] = diff["unexpected"]
        if has_prompt_drift:
            result["prompt_details"] = prompt_result.get("details", "")
            result["prompt_instructions"] = prompt_result.get("instructions", [])
        if plugin_skipped:
            result["plugins_skipped"] = f"runtime {args.runtime} does not use opencode.json plugin array"
        print(json.dumps(result))
        return 1

    # Apply: write backup, update data, write file.
    suffix = args.backup_suffix or __import__("datetime").datetime.now().strftime(
        "%Y%m%d-%H%M%S"
    )
    backup_path = f"{args.file}.backup.{suffix}"
    shutil.copy2(args.file, backup_path)

    if has_plugin_drift and not plugin_skipped:
        data["plugin"] = repair(data, expected)

    prompt_migration_status = "ok"
    if has_prompt_drift:
        apply_prompt_migration(data)
        prompt_migration_status = "migrated"

    with open(args.file, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

    result = {
        "status": "repaired",
        "before": current,
        "after": data.get("plugin", current),
        "backup": backup_path,
        "prompt_migration": prompt_migration_status,
    }
    print(json.dumps(result))
    return 1

    # Apply: write backup, update data, write file.
    suffix = args.backup_suffix or __import__("datetime").datetime.now().strftime(
        "%Y%m%d-%H%M%S"
    )
    backup_path = f"{args.file}.backup.{suffix}"
    shutil.copy2(args.file, backup_path)

    data["plugin"] = repair(data, expected)

    with open(args.file, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

    print(
        json.dumps(
            {
                "status": "repaired",
                "before": current,
                "after": data["plugin"],
                "backup": backup_path,
            }
        )
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
