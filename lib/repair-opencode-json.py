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

Modes:
  default          diagnose drift; exit 1 on drift, 0 on clean
  --additive       add missing managed plugin entries + apply prompt
                   migration; never remove unexpected entries; exit 0
                   unless there is unexpected drift that still needs
                   attention (then exit 1 with status=needs_full_repair)
  --apply          full reconcile — replace plugin array with exactly
                   what setup would produce today (removes unexpected
                   entries). Also applies prompt migration.

Exit codes:
  0 — file is clean OR additive repair completed with no unexpected drift
  1 — drift detected without --apply; OR --additive left unexpected
      entries that need --apply to remove
  2 — usage / IO error

Output (stdout): JSON diagnostic object. Examples:

  {"status":"ok","plugins":[...],"prompt_migration":"ok"}
  {"status":"drift","missing":[...],"unexpected":[...],...,"prompt_migration":"needed"}
  {"status":"additive_repaired","before":[...],"after":[...],"added":[...],"backup":"...","prompt_migration":"migrated"}
  {"status":"needs_full_repair","after":[...],"unexpected":[...]}
  {"status":"repaired","before":[...],"after":[...],"backup":"/path/to/backup","prompt_migration":"migrated"}

CLI usage:
  repair-opencode-json.py --file <path> \
    --runtime <opencode|claude-code|studio-code> \
    --chat-bridge <kimaki|cc-connect|telegram|none> \
    [--kimaki-plugins-dir <path>] \
    [--additive | --apply] \
    [--backup-suffix <timestamp>]

Without --additive or --apply the tool is a pure diagnostic.

--additive is the default mode called from setup.sh and upgrade.sh: it
installs managed plugin entries the user is missing (dm-context-filter,
dm-agent-sync, opencode-claude-auth — whichever apply to the detected
runtime + chat-bridge combo) and migrates legacy agent prompts to the
top-level `instructions` array (fixes Anthropic Claude Max OAuth, see
wp-coding-agents#60). It never removes user-added plugin entries.

--apply is the opt-in full reconciliation, used by
`upgrade.sh --repair-opencode-json`. It removes unexpected plugin
entries in addition to the additive behaviour above.
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
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--apply",
        action="store_true",
        help=(
            "Full reconciliation: replace plugin array with exactly what "
            "setup would produce today (removes unexpected entries). "
            "Also applies prompt migration. Writes a .backup.<suffix> "
            "alongside."
        ),
    )
    mode_group.add_argument(
        "--additive",
        action="store_true",
        help=(
            "Additive repair: add missing managed plugin entries and apply "
            "prompt migration. Never removes unexpected entries. Writes a "
            ".backup.<suffix> alongside. Use this from setup/upgrade "
            "scripts to fix security-critical plugin drift without "
            "clobbering user-added entries."
        ),
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
            result["plugins_skipped"] = (
                f"runtime {args.runtime} does not use opencode.json plugin array"
            )
        print(json.dumps(result))
        return 0

    # Diagnostic mode (no --apply, no --additive): report drift, exit 1.
    if not args.apply and not args.additive:
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
            result["plugins_skipped"] = (
                f"runtime {args.runtime} does not use opencode.json plugin array"
            )
        print(json.dumps(result))
        return 1

    # Write mode (--apply or --additive): back up, mutate, write, report.
    suffix = args.backup_suffix or __import__("datetime").datetime.now().strftime(
        "%Y%m%d-%H%M%S"
    )
    backup_path = f"{args.file}.backup.{suffix}"
    shutil.copy2(args.file, backup_path)

    if has_plugin_drift and not plugin_skipped:
        # --apply:    replace with exactly `expected` (removes unexpected).
        # --additive: merge missing entries, preserving user additions.
        data["plugin"] = repair(data, expected, preserve_extras=args.additive)

    prompt_migration_status = "ok"
    if has_prompt_drift:
        apply_prompt_migration(data)
        prompt_migration_status = "migrated"

    with open(args.file, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

    after_plugins: List[str] = list(data.get("plugin", current))
    added = [p for p in expected if p in after_plugins and p not in current]
    still_unexpected = [p for p in after_plugins if p not in set(expected)]

    if args.additive:
        # Additive leaves unexpected entries alone. If there were any,
        # flag them so the caller knows a full reconcile is still needed.
        status = "needs_full_repair" if still_unexpected else "additive_repaired"
        result = {
            "status": status,
            "before": current,
            "after": after_plugins,
            "added": added,
            "backup": backup_path,
            "prompt_migration": prompt_migration_status,
        }
        if still_unexpected:
            result["unexpected"] = still_unexpected
        print(json.dumps(result))
        # Exit 0 on a clean additive repair; 1 when user still needs to
        # run --apply to remove unexpected entries.
        return 1 if still_unexpected else 0

    result = {
        "status": "repaired",
        "before": current,
        "after": after_plugins,
        "backup": backup_path,
        "prompt_migration": prompt_migration_status,
    }
    print(json.dumps(result))
    return 1


if __name__ == "__main__":
    sys.exit(main())
