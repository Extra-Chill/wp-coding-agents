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
  3. Data Machine managed instruction paths — when supplied by upgrade/setup,
      keep top-level `instructions` aligned to Data Machine's injectable memory
      files while preserving non-Data-Machine user entries.
  4. OpenCode edit permissions — preserve user rules and append managed denies
      for installed WordPress source paths.

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
    --runtime <opencode|claude-code> \
    --chat-bridge <kimaki|cc-connect|telegram|none> \
    [--kimaki-plugins-dir <path>] \
    [--claude-code-auth-plugin <path>] \
    [--additive | --apply] \
    [--backup-suffix <timestamp>]

Without --additive or --apply the tool is a pure diagnostic.

--additive is the default mode called from setup.sh and upgrade.sh: it
installs managed plugin entries the user is missing (dm-context-filter
and dm-agent-sync on Kimaki bridges), removes retired managed plugin
entries, and migrates legacy agent prompts to the top-level `instructions`
array (fixes Anthropic Claude Max OAuth, see wp-coding-agents#60). It never
removes user-added plugin entries.

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
from typing import List, Tuple


MANAGED_KIMAKI_PLUGIN_NAMES = {"dm-context-filter.ts", "dm-agent-sync.ts", "kimaki-session-attribution.ts"}
OBSOLETE_KIMAKI_PLUGIN_NAMES = {"homeboy-notification-context.ts"}
DM_MEMORY_MARKER = "/datamachine-files/"
PROJECTED_MEMORY_MARKER = "/.wp-coding-agents/context/"
# Every installed path wp-coding-agents manages, as ready-made edit patterns in
# canonical order. Denied under BOTH modes.
#
# Directories carry /**; root files are exact literals. That distinction is not
# cosmetic: OpenCode's matcher turns `*` into `.*`, which spans slashes, so a
# pattern like `wp-*.php` would also match wp-content/plugins/acme/wp-thing.php
# and over-deny inside a site's own component. Literals anchor to the root.
#
# wp-admin and the root bootstrap are core, siblings of wp-includes rather than
# nested in it. wp-content/mu-plugins is agent governance: the mu-plugin that
# generates AGENTS.md lives there.
MANAGED_ROOTS = (
    "wp-admin/**",
    "wp-includes/**",
    "wp-content/plugins/**",
    "wp-content/themes/**",
    "wp-content/mu-plugins/**",
    "wp-config.php",
    "wp-settings.php",
    "wp-load.php",
    "wp-blog-header.php",
    "wp-cron.php",
    "wp-login.php",
    "wp-mail.php",
    "wp-signup.php",
    "wp-activate.php",
    "wp-trackback.php",
    "wp-comments-post.php",
    "wp-links-opml.php",
    "xmlrpc.php",
    "index.php",
)
DEFAULT_SOURCE_MODE = "workspace"

def expected_plugins(
    runtime: str,
    chat_bridge: str,
    kimaki_plugins_dir: str,
    claude_code_auth_plugin: str = "",
) -> List[str]:
    """Return the `plugin` array wp-coding-agents setup would produce today.

    Mirrors the logic in runtimes/opencode.sh. Keep in sync when that file
    changes. Order matters — setup.sh writes them in this order.
    """
    plugins: List[str] = []

    if runtime != "opencode":
        # Non-opencode runtimes don't use the opencode.json plugin array.
        # Claude Code has its own config. Return empty so
        # "drift" comparisons on those runtimes are no-ops.
        return plugins

    # DM context filter + memory sync: only when the bridge is Kimaki. These
    # plugins filter Kimaki-specific prompt sections and refresh composed Data
    # Machine memory; they do not write OpenCode agent prompts. wp-coding-agents does
    # not manage opencode-claude-auth on any bridge — Kimaki ships its own
    # AnthropicAuthPlugin, and non-kimaki bridges use opencode's native auth
    # flow. See wp-coding-agents#117.
    if chat_bridge == "kimaki":
        plugins.append(f"{kimaki_plugins_dir}/dm-context-filter.ts")
        plugins.append(f"{kimaki_plugins_dir}/dm-agent-sync.ts")
        plugins.append(f"{kimaki_plugins_dir}/kimaki-session-attribution.ts")

    if claude_code_auth_plugin:
        plugins.append(claude_code_auth_plugin)

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


def normalize_managed_kimaki_plugin_paths(
    current: List[str], kimaki_plugins_dir: str
) -> Tuple[List[str], List[dict]]:
    """Rewrite managed Kimaki plugin paths to the durable configured dir.

    Older local installs pointed opencode.json at npm package-local plugin files
    under ``$(npm root -g)/kimaki/plugins``. Those files disappear on
    ``npm update -g kimaki``. Treat any managed plugin basename outside the
    configured persistent dir as a stale wp-coding-agents-owned entry and rewrite
    it in place, preserving user-added plugins.
    """
    normalized: List[str] = []
    rewrites: List[dict] = []
    seen = set()
    plugins_dir = kimaki_plugins_dir.rstrip("/")

    for plugin in current:
        basename = os.path.basename(plugin)
        if basename in OBSOLETE_KIMAKI_PLUGIN_NAMES:
            rewrites.append({"from": plugin, "to": None})
            continue
        replacement = plugin
        if basename in MANAGED_KIMAKI_PLUGIN_NAMES:
            expected = f"{plugins_dir}/{basename}"
            if os.path.dirname(plugin).rstrip("/") != plugins_dir:
                replacement = expected
                rewrites.append({"from": plugin, "to": replacement})

        if replacement not in seen:
            normalized.append(replacement)
            seen.add(replacement)

    return normalized, rewrites


def repair(
    data: dict, expected: List[str], preserve_extras: bool = False
) -> List[str]:
    """Return the repaired `plugin` array.

    Default behaviour: replace `plugin` with exactly `expected`. This removes
    stale entries left behind by older wp-coding-agents versions (e.g.
    `opencode-claude-auth@latest`, which is no longer managed — see #117).

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


def is_default_only_agent_block(block: object, top_model: object) -> bool:
    """Return whether an agent block is only OpenCode default-equivalent data."""
    if not isinstance(block, dict):
        return False

    keys = set(block.keys())
    if not keys <= {"mode", "model"}:
        return False
    if block.get("mode", "primary") != "primary":
        return False
    if "model" in block and block.get("model") != top_model:
        return False
    return True


def check_agent_cleanup(data: dict) -> dict:
    """Check for default-only persisted build/plan agent shells."""
    agent = data.get("agent", {})
    if not isinstance(agent, dict):
        return {"status": "ok", "remove": []}

    top_model = data.get("model")
    remove = [
        sub
        for sub in ("build", "plan")
        if is_default_only_agent_block(agent.get(sub), top_model)
    ]
    return {"status": "needed" if remove else "ok", "remove": remove}


def apply_agent_cleanup(data: dict) -> List[str]:
    """Remove default-only persisted build/plan agent shells from *data*."""
    result = check_agent_cleanup(data)
    agent = data.get("agent", {})
    if not isinstance(agent, dict):
        return []

    for sub in result["remove"]:
        agent.pop(sub, None)

    if not agent:
        data.pop("agent", None)

    return result["remove"]


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
    # Merge with any existing instructions, preserving user-added entries.
    existing = set(data.get("instructions", []))
    merged = list(data.get("instructions", []))
    for p in new_instructions:
        if p not in existing:
            merged.append(p)
    data["instructions"] = merged

    apply_agent_cleanup(data)

    return result


def read_managed_instructions(path: str) -> List[str]:
    if not path:
        return []
    with open(path, "r", encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip()]


def is_dm_managed_instruction(value: object) -> bool:
    if not isinstance(value, str):
        return False
    normalized = value.replace("\\", "/")
    return DM_MEMORY_MARKER in normalized or PROJECTED_MEMORY_MARKER in normalized


def check_instruction_sync(data: dict, desired: List[str]) -> dict:
    if not desired:
        return {"status": "ok", "desired": []}

    current = list(data.get("instructions", []))
    current_managed = [item for item in current if is_dm_managed_instruction(item)]
    status = "ok" if current_managed == desired else "needed"
    return {
        "status": status,
        "desired": desired,
        "current_managed": current_managed,
    }


def apply_instruction_sync(data: dict, desired: List[str]) -> dict:
    result = check_instruction_sync(data, desired)
    if result["status"] != "needed":
        return result

    preserved = [
        item
        for item in list(data.get("instructions", []))
        if not is_dm_managed_instruction(item)
    ]
    merged: List[str] = []
    for item in [*desired, *preserved]:
        if item not in merged:
            merged.append(item)
    data["instructions"] = merged
    return result


def canonical_source_mode(mode: str) -> str:
    """Translate a pre-rename posture name to its source-mode equivalent.

    The shell does this in source_policy_canonical_mode; the reconciler is
    reachable directly (and by an operator scripting it), so it has to agree.
    A caller passing "managed" and silently getting the workspace ruleset would
    produce an owned install with no editable source at all.
    """
    return {"engineering": "workspace", "managed": "owned"}.get(mode, mode)


def expected_edit_permission(
    data: dict,
    source_mode: str = DEFAULT_SOURCE_MODE,
    owned_sources: List[str] | None = None,
    owned_writable: List[str] | None = None,
    log_paths: List[str] | None = None,
) -> dict:
    """User rules, then managed denies, then the narrower allows.

    KEY ORDER IS THE PRECEDENCE MECHANISM. OpenCode evaluates with findLast over
    a ruleset built in JSON key order, so broad denies have to come before the
    allows that carve exceptions out of them. Emitting the allows first would
    silently invert the policy.
    """
    is_owned = canonical_source_mode(source_mode) == "owned"
    sources = list(owned_sources or []) if is_owned else []
    writable = list(owned_writable or []) if is_owned else []
    logs = list(log_paths or [])

    source_keys = [f"{path}/**" for path in sources]
    # A log path may be a directory or a single file; emit both forms.
    log_keys = [k for path in logs for k in (path, f"{path}/**")]
    managed_keys = set(MANAGED_ROOTS) | set(source_keys) | set(writable) | set(log_keys)

    permission = data.get("permission", {})
    if isinstance(permission, str):
        current: object = permission
    elif isinstance(permission, dict):
        current = permission.get("edit", {})
    else:
        current = {}

    if isinstance(current, str):
        rules = {"*": current}
    elif isinstance(current, dict):
        rules = {
            pattern: action
            for pattern, action in current.items()
            if pattern not in managed_keys and not _is_stale_managed_key(pattern)
        }
    else:
        rules = {}

    for pattern in MANAGED_ROOTS:
        rules[pattern] = "deny"
    for pattern in source_keys:
        rules[pattern] = "allow"
    for pattern in writable:
        rules[pattern] = "allow"
    # Logs are diagnostic input. external_directory would otherwise inherit an
    # allow for edits on them.
    for pattern in log_keys:
        rules[pattern] = "deny"
    return rules


def _is_stale_managed_key(pattern: str) -> bool:
    """True for an owned-source allow this install no longer declares.

    Without this a path dropped from --owned-source would keep its allow rule
    forever, which is the drift the reconciler exists to prevent.
    """
    return (
        pattern.startswith(("wp-content/plugins/", "wp-content/themes/", "/"))
        and pattern.endswith("/**")
    )


def expected_external_directory(
    data: dict,
    workspace_dirs: List[str] | None = None,
    log_paths: List[str] | None = None,
) -> dict:
    """Return user external_directory rules followed by the managed grants.

    #316: the reconciler owned permission.edit only, so an engineering->managed
    upgrade kept a stale workspace grant, and log paths declared at upgrade time
    never landed at all. Both halves of the policy have to be reconciled or the
    upgrade path silently diverges from a fresh install.
    """
    workspaces = list(workspace_dirs or [])
    logs = list(log_paths or [])
    managed: dict[str, str] = {}
    for path in workspaces:
        managed[f"{path}/**"] = "allow"
    for path in logs:
        # Directory or single file; see the log-path rules in edit permissions.
        managed[path] = "allow"
        managed[f"{path}/**"] = "allow"

    permission = data.get("permission", {})
    current = permission.get("external_directory") if isinstance(permission, dict) else None

    if isinstance(current, dict):
        rules = {
            pattern: action
            for pattern, action in current.items()
            if pattern not in managed and not _is_owned_external_key(pattern)
        }
    else:
        rules = {}

    rules.update(managed)
    return rules


def _is_owned_external_key(pattern: str) -> bool:
    """True for a grant wp-coding-agents previously wrote and no longer declares.

    Absolute paths are ours to manage here; anything relative was added by the
    operator and is preserved.
    """
    return pattern.startswith("/") or pattern.startswith("~")


def check_external_directory(
    data: dict,
    runtime: str,
    workspace_dirs: List[str] | None = None,
    log_paths: List[str] | None = None,
) -> dict:
    if runtime != "opencode":
        return {"status": "ok"}
    permission = data.get("permission", {})
    current = permission.get("external_directory") if isinstance(permission, dict) else None
    expected = expected_external_directory(data, workspace_dirs, log_paths)
    if not expected and current in (None, {}):
        return {"status": "ok"}
    return {
        "status": "ok" if current == expected else "needed",
        "expected": expected,
    }


def apply_external_directory(
    data: dict,
    workspace_dirs: List[str] | None = None,
    log_paths: List[str] | None = None,
) -> None:
    expected = expected_external_directory(data, workspace_dirs, log_paths)
    permission = data.get("permission", {})
    if not isinstance(permission, dict):
        permission = {}
    if expected:
        permission["external_directory"] = expected
    else:
        permission.pop("external_directory", None)
    data["permission"] = permission


def check_edit_permission(
    data: dict,
    runtime: str,
    source_mode: str = DEFAULT_SOURCE_MODE,
    owned_sources: List[str] | None = None,
    owned_writable: List[str] | None = None,
    log_paths: List[str] | None = None,
) -> dict:
    if runtime != "opencode":
        return {"status": "ok"}

    permission = data.get("permission", {})
    current = permission.get("edit") if isinstance(permission, dict) else None
    expected = expected_edit_permission(data, source_mode, owned_sources, owned_writable, log_paths)
    return {
        "status": "ok" if current == expected else "needed",
        "expected": expected,
    }


def apply_edit_permission(
    data: dict,
    source_mode: str = DEFAULT_SOURCE_MODE,
    owned_sources: List[str] | None = None,
    owned_writable: List[str] | None = None,
    log_paths: List[str] | None = None,
) -> None:
    expected = expected_edit_permission(data, source_mode, owned_sources, owned_writable, log_paths)
    permission = data.get("permission", {})
    if isinstance(permission, str):
        permission = {"*": permission}
    elif not isinstance(permission, dict):
        permission = {}
    permission["edit"] = expected
    data["permission"] = permission


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, help="Path to opencode.json")
    parser.add_argument(
        "--runtime",
        required=True,
        choices=["opencode", "claude-code"],
    )
    parser.add_argument(
        "--chat-bridge",
        required=True,
        choices=["kimaki", "cc-connect", "telegram", "none"],
    )
    parser.add_argument(
        "--source-mode",
        default=DEFAULT_SOURCE_MODE,
        choices=["workspace", "owned", "engineering", "managed"],
        help="Installed-source mode for this install (see lib/source-policy.sh)",
    )
    parser.add_argument(
        "--owned-source",
        action="append",
        default=[],
        dest="owned_sources",
        help="wp-content path this site owns and may edit under owned source mode. Repeatable.",
    )
    parser.add_argument(
        "--owned-writable",
        action="append",
        default=[],
        dest="owned_writable",
        help="Denied path this install explicitly re-opens for editing. Not captured. Repeatable.",
    )
    parser.add_argument(
        "--workspace-dir",
        action="append",
        default=[],
        dest="workspace_dirs",
        help="Declared workspace checkout root to grant via external_directory (workspace mode only). Repeatable.",
    )
    parser.add_argument(
        "--log-path",
        action="append",
        default=[],
        dest="log_paths",
        help="Absolute path outside the site root the agent may read. Repeatable.",
    )
    parser.add_argument(
        "--kimaki-plugins-dir",
        default="/opt/kimaki-config/plugins",
        help="Directory where DM plugins live (VPS default: /opt/kimaki-config/plugins)",
    )
    parser.add_argument(
        "--claude-code-auth-plugin",
        default="",
        help="Optional managed OpenCode Claude Code OAuth auth plugin path",
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
    parser.add_argument(
        "--managed-instructions-file",
        default="",
        help=(
            "Newline-delimited Data Machine injectable instruction paths. "
            "Only existing datamachine-files entries are replaced; user entries are preserved."
        ),
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
    agent_cleanup_result = check_agent_cleanup(data)
    managed_instructions = read_managed_instructions(args.managed_instructions_file)
    instruction_sync_result = check_instruction_sync(data, managed_instructions)
    edit_permission_result = check_edit_permission(data, args.runtime, args.source_mode, args.owned_sources, args.owned_writable, args.log_paths)
    external_directory_result = check_external_directory(data, args.runtime, args.workspace_dirs, args.log_paths)

    # --- Plugin array check ---
    expected = expected_plugins(
        runtime=args.runtime,
        chat_bridge=args.chat_bridge,
        kimaki_plugins_dir=args.kimaki_plugins_dir.rstrip("/"),
        claude_code_auth_plugin=args.claude_code_auth_plugin,
    )

    current: List[str] = list(data.get("plugin", []))
    normalized_current = current
    plugin_rewrites: List[dict] = []
    if args.runtime == "opencode" and args.chat_bridge == "kimaki":
        normalized_current, plugin_rewrites = normalize_managed_kimaki_plugin_paths(
            current,
            args.kimaki_plugins_dir,
        )

    # Claude Code: no plugin array concept here. Report ok
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

    diff = diff_plugins(normalized_current, expected)
    has_plugin_drift = bool(diff["missing"] or diff["unexpected"] or plugin_rewrites)
    has_prompt_drift = prompt_result["status"] == "needed"
    has_agent_cleanup_drift = agent_cleanup_result["status"] == "needed"
    has_instruction_drift = instruction_sync_result["status"] == "needed"
    has_edit_permission_drift = edit_permission_result["status"] == "needed"
    has_external_directory_drift = external_directory_result["status"] == "needed"
    has_any_drift = (
        has_plugin_drift
        or has_prompt_drift
        or has_agent_cleanup_drift
        or has_instruction_drift
        or has_edit_permission_drift
        or has_external_directory_drift
    )

    if not has_any_drift:
        result: dict = {
            "status": "ok",
            "plugins": current,
            "prompt_migration": "ok",
            "agent_cleanup": "ok",
            "instruction_sync": "ok",
            "edit_permission": "ok",
            "external_directory": "ok",
        }
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
            "agent_cleanup": agent_cleanup_result["status"],
            "instruction_sync": instruction_sync_result["status"],
            "edit_permission": edit_permission_result["status"],
            "external_directory": external_directory_result["status"],
        }
        if plugin_rewrites:
            result["rewritten"] = plugin_rewrites
        if has_plugin_drift:
            result["missing"] = diff["missing"]
            result["unexpected"] = diff["unexpected"]
        if has_prompt_drift:
            result["prompt_details"] = prompt_result.get("details", "")
            result["prompt_instructions"] = prompt_result.get("instructions", [])
        if has_agent_cleanup_drift:
            result["agent_cleanup_remove"] = agent_cleanup_result.get("remove", [])
        if has_instruction_drift:
            result["instruction_sync_desired"] = instruction_sync_result.get("desired", [])
            result["instruction_sync_current"] = instruction_sync_result.get("current_managed", [])
        if has_edit_permission_drift:
            result["edit_permission_expected"] = edit_permission_result["expected"]
        if has_external_directory_drift:
            result["external_directory_expected"] = external_directory_result["expected"]
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
        repaired_data = dict(data)
        repaired_data["plugin"] = normalized_current
        data["plugin"] = repair(repaired_data, expected, preserve_extras=args.additive)

    prompt_migration_status = "ok"
    if has_prompt_drift:
        apply_prompt_migration(data)
        prompt_migration_status = "migrated"

    removed_agent_blocks = apply_agent_cleanup(data)

    instruction_sync_status = "ok"
    if has_instruction_drift:
        apply_instruction_sync(data, managed_instructions)
        instruction_sync_status = "synced"

    edit_permission_status = "ok"
    if has_edit_permission_drift:
        apply_edit_permission(data, args.source_mode, args.owned_sources, args.owned_writable, args.log_paths)
        edit_permission_status = "synced"
    external_directory_status = "ok"
    if has_external_directory_drift:
        apply_external_directory(data, args.workspace_dirs, args.log_paths)
        external_directory_status = "synced"

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
            "agent_cleanup": "removed" if removed_agent_blocks else "ok",
            "instruction_sync": instruction_sync_status,
            "edit_permission": edit_permission_status,
        "external_directory": external_directory_status,
            "external_directory": external_directory_status,
        }
        if plugin_rewrites:
            result["rewritten"] = plugin_rewrites
        if removed_agent_blocks:
            result["agent_cleanup_removed"] = removed_agent_blocks
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
        "agent_cleanup": "removed" if removed_agent_blocks else "ok",
        "instruction_sync": instruction_sync_status,
        "edit_permission": edit_permission_status,
    }
    if plugin_rewrites:
        result["rewritten"] = plugin_rewrites
    if removed_agent_blocks:
        result["agent_cleanup_removed"] = removed_agent_blocks
    print(json.dumps(result))
    return 1


if __name__ == "__main__":
    sys.exit(main())
