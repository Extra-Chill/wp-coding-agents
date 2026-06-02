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
#   agents_md_guidance_register_homeboy_codebox
#   agents_md_guidance_unregister_homeboy_codebox
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
## Homeboy Agent Tasks

Use Homeboy `agent-task` for async coding-agent fan-out instead of manual chat-session fleets. Homeboy owns task plans, durable run state, queueing, concurrency, retries, logs, artifacts, and promotion back into the review workflow.

**Codebox executor:** the `codebox` backend runs each task in a disposable WP Codebox WordPress sandbox. WP Codebox owns sandbox recipes, plugin/runtime overlays, agent invocation, and artifact bundles; Homeboy owns orchestration around those recipes.

**Common verbs:** `homeboy agent-task submit|run|run-plan|status|logs|artifacts|promote`. Use `homeboy agent-task providers` to inspect registered executor providers.

**Workspace shape:** pass an explicit workspace root for code edits, usually a Data Machine Code worktree under `/Users/chubes/Developer/<repo>@<slug>` locally or the equivalent mounted path inside a sandbox. Keep primary checkouts read-only and cook changes in worktrees.

**WP Codebox agent mode:** use sandbox mode for Codebox coding tasks. Sandbox mode exposes the bounded workspace tools needed to read, edit, and verify files; conversational/default chat mode is only useful for answering questions.

**Codex provider:** Codebox Codex tasks need the OpenAI Codex provider plugin/runtime overlay and `AI_PROVIDER_OPENAI_CODEX_*` secrets passed via `secret_env`. Never print token values in logs or task instructions.

Use Kimaki, Discord, or other chat bridges as thin transport only. They should display task status and results, not own fleet scheduling or spawn worker sessions themselves.
MD
}

_agents_md_guidance_render_block() {
  local section_id="$1" priority="$2" label="$3" description="$4" content="$5"
  AGENTS_MD_GUIDANCE_SECTION_ID="$section_id" \
  AGENTS_MD_GUIDANCE_PRIORITY="$priority" \
  AGENTS_MD_GUIDANCE_LABEL="$label" \
  AGENTS_MD_GUIDANCE_DESCRIPTION="$description" \
  AGENTS_MD_GUIDANCE_CONTENT="$content" \
  python3 <<'PY'
import os
import re
import sys

section_id = os.environ["AGENTS_MD_GUIDANCE_SECTION_ID"]
priority = os.environ["AGENTS_MD_GUIDANCE_PRIORITY"]
label = os.environ["AGENTS_MD_GUIDANCE_LABEL"]
description = os.environ.get("AGENTS_MD_GUIDANCE_DESCRIPTION", "")
content = os.environ["AGENTS_MD_GUIDANCE_CONTENT"].rstrip("\n")

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
print("        )")
print("    );")
print(f"    // END agents-md-guidance:{section_id}")
PY
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
