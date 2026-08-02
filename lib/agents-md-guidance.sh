#!/bin/bash
# lib/agents-md-guidance.sh — AGENTS.md SectionRegistry guidance MECHANISM.
#
# wp-coding-agents owns integration-specific runtime guidance for the tools it
# installs and wires together. Data Machine Code owns the generic AGENTS.md
# composition substrate; this helper publishes wp-coding-agents' integration
# guidance into that substrate through Data Machine's SectionRegistry without
# making DMC know about Homeboy, Kimaki, OpenCode, or WP Codebox conventions.
#
# This file is the mechanism ONLY: scaffold the mu-plugin, render a
# marker-delimited PHP block, rewrite it idempotently, remove it on request. It
# has no opinion about what any section says. The prose lives in guidance/*.sh,
# one self-contained unit per section, discovered and dispatched by
# guidance/_dispatch.sh — see that file for the hook contract and for how
# posture selects between section variants.
#
# Resolved file: $SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agents-md.php
#
# Public surface:
#   agents_md_guidance_mu_plugin_path
#   agents_md_guidance_ensure_mu_plugin_file
#   agents_md_guidance_register <section_id> <priority> <label> <description> <content>
#   agents_md_guidance_unregister <section_id>
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
    _agents_md_guidance_normalize_action_priority "$file"
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
    if ( ! function_exists( 'datamachine_agents_md_enabled' ) || ! datamachine_agents_md_enabled() ) {
        return;
    }

    if ( ! class_exists( '\DataMachine\Engine\AI\SectionRegistry' ) ) {
        return;
    }

    // BEGIN agents-md-guidance-sections
    // END agents-md-guidance-sections
}, 100 );
PHP

  service_file_normalize_perms "$file"
  log "  Wrote AGENTS.md guidance mu-plugin scaffold: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("created $file")
  fi
}

_agents_md_guidance_normalize_action_priority() {
  local file="$1"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would normalize AGENTS.md guidance registration priority in $file"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  python3 - "$file" > "$tmp" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
marker = "    // END agents-md-guidance-sections"
current = marker + "\n}, 100 );"
legacy = marker + "\n} );"
if content.count(current) == 1:
    sys.stdout.write(content)
    raise SystemExit(0)
if content.count(legacy) != 1:
    raise SystemExit("AGENTS.md guidance mu-plugin has an unexpected action wrapper")
sys.stdout.write(content.replace(legacy, current))
PY
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$file"
  service_file_normalize_perms "$file"
  log "  Normalized AGENTS.md guidance registration priority in $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance registration priority")
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
  service_file_normalize_perms "$file"
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
  service_file_normalize_perms "$file"
  log "  Unregistered AGENTS.md guidance section '$section_id' from $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance removed: $section_id")
  fi
}

_agents_md_guidance_render_block() {
  local section_id="$1" priority="$2" label="$3" description="$4" content="$5"
  AGENTS_MD_GUIDANCE_SECTION_ID="$section_id" \
  AGENTS_MD_GUIDANCE_PRIORITY="$priority" \
  AGENTS_MD_GUIDANCE_LABEL="$label" \
  AGENTS_MD_GUIDANCE_DESCRIPTION="$description" \
  AGENTS_MD_GUIDANCE_CONTENT="$content" \
  AGENTS_MD_GUIDANCE_FRESHNESS="${AGENTS_MD_GUIDANCE_FRESHNESS:-conditional}" \
  AGENTS_MD_GUIDANCE_CONDITIONS="${AGENTS_MD_GUIDANCE_CONDITIONS:-Registered by wp-coding-agents when the integration is available; removed when unavailable.}" \
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
