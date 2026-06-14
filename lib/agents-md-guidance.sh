#!/bin/bash
# lib/agents-md-guidance.sh — AGENTS.md SectionRegistry guidance writer.
#
# wp-coding-agents owns integration-specific runtime guidance for the tools it
# installs and wires together. Data Machine Code owns the generic AGENTS.md
# composition substrate; this helper publishes wp-coding-agents' integration
# guidance into that substrate through Data Machine's SectionRegistry without
# making DMC know about Homeboy, Kimaki, OpenCode, or WP Codebox conventions.
#
# Resolved file: $SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agents-md.php
#
# Public surface:
#   agents_md_guidance_mu_plugin_path
#   agents_md_guidance_ensure_mu_plugin_file
#   agents_md_guidance_register <section_id> <priority> <label> <description> <content>
#   agents_md_guidance_unregister <section_id>
#   agents_md_guidance_sync_homeboy_codebox <available:true|false>
#   agents_md_guidance_register_homeboy_codebox
#   agents_md_guidance_unregister_homeboy_codebox
#   agents_md_guidance_sync_homeboy_cli          # presence-gated on `command -v homeboy`
#   agents_md_guidance_register_homeboy_cli
#   agents_md_guidance_unregister_homeboy_cli
#   agents_md_guidance_homeboy_cli_content       # renders section body from `homeboy --help`
#
# Honors DRY_RUN (logs intent, makes no changes).

agents_md_guidance_mu_plugin_path() {
  if [ -z "${SITE_PATH:-}" ]; then
    return 1
  fi
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agents-md.php"
}

agents_md_guidance_ensure_mu_plugin_file() {
  local file
  file="$(agents_md_guidance_mu_plugin_path)" || {
    warn "  agents_md_guidance_ensure_mu_plugin_file: SITE_PATH not set — skipping"
    return 1
  }

  if [ -f "$file" ]; then
    return 0
  fi

  local dir="${file%/*}"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mkdir -p $dir"
    echo -e "${BLUE}[dry-run]${NC} Would write AGENTS.md guidance mu-plugin to $file"
    return 0
  fi

  mkdir -p "$dir"
  cat > "$file" <<'PHP'
<?php
/**
 * Plugin Name: wp-coding-agents — AGENTS.md guidance registry
 * Description: Registers wp-coding-agents-owned integration guidance as
 *              composable AGENTS.md sections through Data Machine's
 *              SectionRegistry. Managed by wp-coding-agents setup/upgrade —
 *              do not edit by hand.
 *
 * Each integration contributes a marker-delimited PHP block of the form:
 *
 *   // BEGIN agents-md-guidance:<section_id>
 *   \DataMachine\Engine\AI\SectionRegistry::register( ... );
 *   // END agents-md-guidance:<section_id>
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

add_action( 'datamachine_sections', function () {
    if ( ! class_exists( '\DataMachine\Engine\AI\SectionRegistry' ) ) {
        return;
    }

    // BEGIN agents-md-guidance-sections
    // END agents-md-guidance-sections
} );
PHP

  chmod 0644 "$file"
  log "  Wrote AGENTS.md guidance mu-plugin scaffold: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("created $file")
  fi
}

agents_md_guidance_register() {
  local section_id="$1" priority="$2" label="$3" description="$4" content="$5"

  if [ -z "$section_id" ] || [ -z "$priority" ] || [ -z "$label" ] || [ -z "$content" ]; then
    warn "  agents_md_guidance_register: missing required args (section_id=$section_id priority=$priority label=$label)"
    return 1
  fi

  _agents_md_guidance_validate_section_id "$section_id" || return 1
  _agents_md_guidance_validate_priority "$priority" || return 1

  local file
  file="$(agents_md_guidance_mu_plugin_path)" || {
    warn "  agents_md_guidance_register: SITE_PATH not set — skipping section '$section_id'"
    return 1
  }

  agents_md_guidance_ensure_mu_plugin_file || return 1

  local new_block
  new_block=$(_agents_md_guidance_render_block "$section_id" "$priority" "$label" "$description" "$content")

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would register AGENTS.md guidance section '$section_id' in $file"
    echo -e "${BLUE}[dry-run]${NC} Block:"
    echo "$new_block" | sed 's/^/    /'
    return 0
  fi

  if _agents_md_guidance_block_matches "$file" "$section_id" "$new_block"; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _agents_md_guidance_rewrite "$file" "$section_id" "$new_block" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  chmod 0644 "$file"
  log "  Registered AGENTS.md guidance section '$section_id' in $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance: $section_id")
  fi
}

agents_md_guidance_unregister() {
  local section_id="$1"
  if [ -z "$section_id" ]; then
    warn "  agents_md_guidance_unregister: missing section_id"
    return 1
  fi

  _agents_md_guidance_validate_section_id "$section_id" || return 1

  local file
  file="$(agents_md_guidance_mu_plugin_path)" || return 0
  [ -f "$file" ] || return 0

  if ! grep -q "// BEGIN agents-md-guidance:${section_id}\$" "$file"; then
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would unregister AGENTS.md guidance section '$section_id' from $file"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _agents_md_guidance_rewrite "$file" "$section_id" "" > "$tmp"
  mv "$tmp" "$file"
  chmod 0644 "$file"
  log "  Unregistered AGENTS.md guidance section '$section_id' from $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance removed: $section_id")
  fi
}

agents_md_guidance_sync_homeboy_codebox() {
  local available="${1:-false}"
  case "$available" in
    true) agents_md_guidance_register_homeboy_codebox ;;
    false) agents_md_guidance_unregister_homeboy_codebox ;;
    *)
      warn "  agents_md_guidance_sync_homeboy_codebox: expected true or false, got '$available'"
      return 1
      ;;
  esac
}

agents_md_guidance_register_homeboy_codebox() {
  agents_md_guidance_register \
    "homeboy-codebox-agent-tasks" \
    36 \
    "Homeboy Codebox agent tasks" \
    "Homeboy-owned async coding-agent fan-out through WP Codebox sandboxes." \
    "$(agents_md_guidance_homeboy_codebox_content)"
}

agents_md_guidance_unregister_homeboy_codebox() {
  agents_md_guidance_unregister "homeboy-codebox-agent-tasks"
}

agents_md_guidance_homeboy_codebox_content() {
  cat <<'MD'
**Agent tasks:** `homeboy agent-task submit|run|run-plan|status|logs|artifacts|promote`; use `homeboy agent-task providers` to inspect registered executor providers. Homeboy owns task plans, durable run state, queueing, concurrency, retries, logs, artifacts, and promotion back into the review workflow.

**Codebox executor:** use the `codebox` backend for disposable WP Codebox WordPress sandboxes. WP Codebox owns sandbox recipes, plugin/runtime overlays, agent invocation, and artifact bundles; Homeboy owns orchestration around those recipes.

**Workspace shape:** pass an explicit workspace root for code edits, usually a Data Machine Code worktree under `<workspace>/<repo>@<slug>` locally or the equivalent mounted path inside a sandbox. Keep primary checkouts read-only.

**WP Codebox agent mode:** use sandbox mode for Codebox coding tasks. Sandbox mode exposes the bounded workspace tools needed to read, edit, and verify files.

**Codex provider:** Codebox Codex tasks need the OpenAI Codex provider plugin/runtime overlay and `AI_PROVIDER_OPENAI_CODEX_*` secrets passed via `secret_env`. Never print token values in logs or task instructions.

**Claude Code provider:** Codebox Claude Code tasks use the `ai-provider-for-claude-code` plugin carried by wp-coding-agents. It is backed by Claude Code OAuth credentials through WP AI Client / PHP AI Client, not the `claude` binary, not an Anthropic API key, and not WP AI Gateway. Provider id: `claude-code`. Provide credentials through `AI_PROVIDER_CLAUDE_CODE_REFRESH_TOKEN` and optional `AI_PROVIDER_CLAUDE_CODE_ACCESS_TOKEN` / `AI_PROVIDER_CLAUDE_CODE_EXPIRES_AT`; never pass Claude subscription/session material through task prompts or logs.

**Operator verbs:** `homeboy release`, `homeboy deploy`, and `homeboy ssh` are operator actions. Use them only when the user explicitly asks for that action.

**Chat bridges:** Kimaki, Discord, and other chat bridges display task status and results while Homeboy remains the source of truth for task state and artifacts.
MD
}

# ---------------------------------------------------------------------------
# Homeboy CLI command map (issue #208)
#
# homeboy is an OPTIONAL host binary. The map is strictly presence-gated:
#   - present (`command -v homeboy` succeeds) -> emit a first-class section
#     generated from `homeboy --help`, refreshed every setup/upgrade so a
#     homeboy version bump auto-refreshes the command list.
#   - absent -> complete no-op (unregister any stale section, emit nothing).
#
# The command list is NEVER hardcoded; it is parsed from `homeboy --help` at
# sync time. A hardcoded list is precisely the drift bug #208 fixes.
# ---------------------------------------------------------------------------

# agents_md_guidance_sync_homeboy_cli
#
# Presence-gated entry point. Reuses the same `command -v homeboy` detection
# the rest of the homeboy integration uses so the section and the integration
# agree on presence.
agents_md_guidance_sync_homeboy_cli() {
  if command -v homeboy >/dev/null 2>&1; then
    agents_md_guidance_register_homeboy_cli
  else
    agents_md_guidance_unregister_homeboy_cli
  fi
}

agents_md_guidance_register_homeboy_cli() {
  local content
  content="$(agents_md_guidance_homeboy_cli_content)" || {
    warn "  agents_md_guidance_register_homeboy_cli: could not enumerate homeboy commands — skipping"
    return 1
  }

  if [ -z "$content" ]; then
    warn "  agents_md_guidance_register_homeboy_cli: homeboy --help produced no commands — skipping"
    return 1
  fi

  AGENTS_MD_GUIDANCE_FRESHNESS="conditional" \
  AGENTS_MD_GUIDANCE_CONDITIONS="Generated from 'homeboy --help' on hosts where the homeboy binary is installed; removed when homeboy is absent." \
  agents_md_guidance_register \
    "homeboy-cli" \
    34 \
    "Homeboy CLI" \
    "Host orchestrator command map, generated from 'homeboy --help'." \
    "$content"
}

agents_md_guidance_unregister_homeboy_cli() {
  agents_md_guidance_unregister "homeboy-cli"
}

# agents_md_guidance_homeboy_cli_content
#
# Renders the Homeboy CLI AGENTS.md section body from live `homeboy --help`
# output. Prints nothing and returns non-zero when homeboy is unavailable or
# emits no parseable command table.
agents_md_guidance_homeboy_cli_content() {
  command -v homeboy >/dev/null 2>&1 || return 1

  local help_text
  help_text="$(homeboy --help 2>/dev/null)" || return 1
  [ -n "$help_text" ] || return 1

  HOMEBOY_HELP_TEXT="$help_text" python3 <<'PY'
import os
import re
import sys

help_text = os.environ.get("HOMEBOY_HELP_TEXT", "")

# Parse the "Commands:" block of `homeboy --help`. Each command line looks like
#   "  agent-task      Run generic agent task plans"
# i.e. leading whitespace, a command token, run of spaces, then the summary.
commands = []
in_commands = False
for raw in help_text.splitlines():
    stripped = raw.strip()
    if not in_commands:
        if stripped == "Commands:":
            in_commands = True
        continue

    # The commands block ends at the first blank line or the Options: header.
    if stripped == "" or stripped == "Options:" or raw.startswith("Options:"):
        break

    m = re.match(r"^\s+([A-Za-z0-9][A-Za-z0-9_-]*)\s{2,}(.+?)\s*$", raw)
    if not m:
        # Continuation / wrapped summary lines have no command token; ignore.
        continue

    name, summary = m.group(1), m.group(2).strip()
    commands.append((name, summary))

if not commands:
    sys.exit(1)

# `help` / `list` are meta commands; drop them from the map (the footer already
# tells the agent how to discover everything).
SKIP = {"help", "list"}
commands = [(n, s) for (n, s) in commands if n not in SKIP]

if not commands:
    sys.exit(1)

lines = []
lines.append(
    "Homeboy is the host orchestrator binary — build, deploy, release, triage, "
    "test, and inspect components from the CLI. It is detected on this host, so "
    "the command map below is generated from `homeboy --help` and refreshes "
    "whenever homeboy is upgraded."
)
lines.append("")
for name, summary in commands:
    lines.append(f"- `homeboy {name}` — {summary}")
lines.append("")
lines.append(
    "Discover everything: `homeboy --help`. Drill into any command with "
    "`homeboy <command> --help`. Releases (`homeboy release`) and deploys "
    "(`homeboy deploy`) are operator actions — run them only when the user "
    "explicitly asks."
)

sys.stdout.write("\n".join(lines))
PY
}

_agents_md_guidance_render_block() {
  local section_id="$1" priority="$2" label="$3" description="$4" content="$5"
  AGENTS_MD_GUIDANCE_SECTION_ID="$section_id" \
  AGENTS_MD_GUIDANCE_PRIORITY="$priority" \
  AGENTS_MD_GUIDANCE_LABEL="$label" \
  AGENTS_MD_GUIDANCE_DESCRIPTION="$description" \
  AGENTS_MD_GUIDANCE_CONTENT="$content" \
  AGENTS_MD_GUIDANCE_FRESHNESS="${AGENTS_MD_GUIDANCE_FRESHNESS:-conditional}" \
  AGENTS_MD_GUIDANCE_CONDITIONS="${AGENTS_MD_GUIDANCE_CONDITIONS:-Registered when Homeboy Codebox agent-task tooling is available; removed when unavailable.}" \
  python3 <<'PY'
import os
import re
import sys

section_id = os.environ["AGENTS_MD_GUIDANCE_SECTION_ID"]
priority = os.environ["AGENTS_MD_GUIDANCE_PRIORITY"]
label = os.environ["AGENTS_MD_GUIDANCE_LABEL"]
description = os.environ.get("AGENTS_MD_GUIDANCE_DESCRIPTION", "")
content = os.environ["AGENTS_MD_GUIDANCE_CONTENT"].rstrip("\n")
freshness = os.environ.get("AGENTS_MD_GUIDANCE_FRESHNESS", "conditional")
conditions = os.environ.get("AGENTS_MD_GUIDANCE_CONDITIONS", "")

if not re.fullmatch(r"[A-Za-z0-9_.-]+", section_id):
    sys.stderr.write("AGENTS.md guidance section id may only contain letters, numbers, dots, underscores, and hyphens\n")
    sys.exit(1)
try:
    priority_int = int(priority)
except ValueError:
    sys.stderr.write("AGENTS.md guidance priority must be an integer\n")
    sys.exit(1)

def esc(value):
    return value.replace("\\", "\\\\").replace("'", "\\'")

print(f"    // BEGIN agents-md-guidance:{section_id}")
print("    \\DataMachine\\Engine\\AI\\SectionRegistry::register(")
print("        'AGENTS.md',")
print(f"        '{esc(section_id)}',")
print(f"        {priority_int},")
print("        static function () {")
print("            return <<<'MD'")
print(content)
print("MD;")
print("        },")
print("        array(")
print(f"            'label'       => '{esc(label)}',")
print(f"            'description' => '{esc(description)}',")
print("            'owner'       => 'wp-coding-agents',")
print(f"            'freshness'   => '{esc(freshness)}',")
print(f"            'conditions'  => '{esc(conditions)}',")
print("        )")
print("    );")
print(f"    // END agents-md-guidance:{section_id}")
PY
}

_agents_md_guidance_validate_section_id() {
  local section_id="$1"
  if printf '%s' "$section_id" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
    return 0
  fi

  warn "  AGENTS.md guidance section id may only contain letters, numbers, dots, underscores, and hyphens: $section_id"
  return 1
}

_agents_md_guidance_validate_priority() {
  local priority="$1"
  if printf '%s' "$priority" | grep -Eq '^-?[0-9]+$'; then
    return 0
  fi

  warn "  AGENTS.md guidance priority must be an integer: $priority"
  return 1
}

_agents_md_guidance_block_matches() {
  local file="$1" section_id="$2" new_block="$3"
  local existing
  existing=$(awk -v sid="$section_id" '
    $0 == "    // BEGIN agents-md-guidance:" sid { capturing=1 }
    capturing { print }
    $0 == "    // END agents-md-guidance:" sid { exit }
  ' "$file")
  [ "$existing" = "$new_block" ]
}

_agents_md_guidance_rewrite() {
  local file="$1" section_id="$2" new_block="$3"
  AGENTS_MD_GUIDANCE_NEW_BLOCK="$new_block" python3 - "$file" "$section_id" <<'PY'
import os
import sys

file_path, section_id = sys.argv[1], sys.argv[2]
new_block = os.environ.get("AGENTS_MD_GUIDANCE_NEW_BLOCK", "")
begin_marker = f"    // BEGIN agents-md-guidance:{section_id}"
end_marker = f"    // END agents-md-guidance:{section_id}"

with open(file_path, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

inserted = False
skipping = False
out = []

for line in lines:
    if line == begin_marker:
        skipping = True
        if new_block:
            out.extend(new_block.splitlines())
            inserted = True
        continue

    if skipping:
        if line == end_marker:
            skipping = False
        continue

    if not inserted and line == "    // END agents-md-guidance-sections":
        if new_block:
            out.extend(new_block.splitlines())
            inserted = True

    out.append(line)

sys.stdout.write("\n".join(out))
sys.stdout.write("\n")
PY
}
