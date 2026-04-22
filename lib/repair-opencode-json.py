#!/usr/bin/env python3
"""
repair-opencode-json.py — Detect and optionally repair the `plugin` array in
an existing opencode.json against what the current wp-coding-agents setup
would produce for the detected (RUNTIME, CHAT_BRIDGE). Data Machine is
always installed.

Exit codes:
  0 — no drift; file is already correct
  1 — drift detected (or repair applied if --apply)
  2 — usage / IO error

Output (stdout): JSON diagnostic object. Examples:

  {"status":"ok","plugins":[...]}
  {"status":"drift","missing":[...],"unexpected":[...],"current":[...],"expected":[...]}
  {"status":"repaired","before":[...],"after":[...],"backup":"/path/to/backup"}

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

    # DM context filter + agent sync: only when DM handles memory via Kimaki.
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

    expected = expected_plugins(
        runtime=args.runtime,
        chat_bridge=args.chat_bridge,
        kimaki_plugins_dir=args.kimaki_plugins_dir.rstrip("/"),
    )

    current: List[str] = list(data.get("plugin", []))

    # Claude Code / Studio Code: no plugin array concept here. Report ok
    # if current is empty or absent; otherwise let user know we skipped.
    if args.runtime != "opencode":
        print(
            json.dumps(
                {
                    "status": "skipped",
                    "reason": f"runtime {args.runtime} does not use opencode.json plugin array",
                    "current": current,
                }
            )
        )
        return 0

    diff = diff_plugins(current, expected)
    has_drift = bool(diff["missing"] or diff["unexpected"])

    if not has_drift:
        print(json.dumps({"status": "ok", "plugins": current}))
        return 0

    if not args.apply:
        print(
            json.dumps(
                {
                    "status": "drift",
                    "missing": diff["missing"],
                    "unexpected": diff["unexpected"],
                    "current": current,
                    "expected": expected,
                }
            )
        )
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
