#!/bin/bash
# Runtime: Codex — install, AGENTS.md generation, project-local skills

CODEX_MANAGED_OVERRIDE_START="<!-- WP_CODING_AGENTS_CODEX_OVERRIDE_START -->"
CODEX_MANAGED_OVERRIDE_END="<!-- WP_CODING_AGENTS_CODEX_OVERRIDE_END -->"
CODEX_DM_MEMORY_START="<!-- WP_CODING_AGENTS_CODEX_MEMORY_START -->"
CODEX_DM_MEMORY_END="<!-- WP_CODING_AGENTS_CODEX_MEMORY_END -->"
CODEX_PERMISSION_START="# BEGIN WP_CODING_AGENTS_WORDPRESS_PERMISSIONS"
CODEX_PERMISSION_END="# END WP_CODING_AGENTS_WORDPRESS_PERMISSIONS"

runtime_install() {
  log "Phase 7: Installing Codex..."

  if ! command -v codex &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g @openai/codex
  else
    log "Codex already installed: $(codex --version 2>/dev/null || echo 'unknown')"
  fi

  _codex_register_runtime_signature
}

# Codex exports CODEX_THREAD_ID into shell/tool subprocesses. Register it so
# Data Machine Code can attribute worktree activity back to the active Codex
# thread when the runtime is launched from a managed site.
_codex_register_runtime_signature() {
  if ! declare -F runtime_signature_register >/dev/null; then
    return 0
  fi
  runtime_signature_register \
    "codex" \
    '{"thread_id":"CODEX_THREAD_ID"}'
}

runtime_discover_dm_paths() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_FLAG=""
    if [ -n "${AGENT_SLUG:-}" ]; then
      AGENT_FLAG="--agent=$AGENT_SLUG"
    fi

    DM_INJECTABLE_RAW=$(wp_cmd datamachine memory injectable-files --format=json $AGENT_FLAG 2>/dev/null || echo "")
    DM_INJECTABLE_JSON=$(echo "$DM_INJECTABLE_RAW" | sed -n '/^\[/,/^\]/p')
    if [ -n "$DM_INJECTABLE_JSON" ]; then
      DM_AGENT_FILES=$(echo "$DM_INJECTABLE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data:
    path = f.get('path')
    if path:
        print(path)
" 2>/dev/null || true)
      if [ -n "$DM_AGENT_FILES" ]; then
        log "Agent files discovered via '$(wp_cli_transport_display) datamachine memory injectable-files${AGENT_FLAG:+ ($AGENT_FLAG)}'"
        return
      fi
    fi

    DM_PATHS_RAW=$(wp_cmd datamachine memory paths --format=json $AGENT_FLAG 2>/dev/null || echo "")
    DM_PATHS_JSON=$(echo "$DM_PATHS_RAW" | sed -n '/^{/,/^}/p')
    if [ -n "$DM_PATHS_JSON" ]; then
      DM_AGENT_FILES=$(echo "$DM_PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
" 2>/dev/null || true)
      if [ -n "$DM_AGENT_FILES" ]; then
        log "Agent files discovered via '$(wp_cli_transport_display) datamachine memory paths${AGENT_FLAG:+ ($AGENT_FLAG)}'"
        return
      fi
    fi

    warn "'$(wp_cli_transport_display) datamachine memory injectable-files' and 'memory paths' returned no JSON — Codex AGENTS.md memory block will be skipped"
    DM_AGENT_FILES=""
  else
    DM_DRY_SLUG="${AGENT_SLUG:-AGENT_SLUG}"
    DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md
wp-content/uploads/datamachine-files/shared/RULES.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/SOUL.md
wp-content/uploads/datamachine-files/users/USER_ID/USER.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/MEMORY.md"
    log "Dry-run: using placeholder agent paths (slug: $DM_DRY_SLUG)"
  fi
}

runtime_generate_config() {
  local config_dir="$SITE_PATH/.codex"
  local config_file="$config_dir/config.toml"
  local config_before config_after

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would configure Codex WordPress source permissions at $config_file"
    return 0
  fi

  config_before="$(cksum "$config_file" 2>/dev/null || true)"
  local version
  version=$(codex --version 2>/dev/null | sed -nE 's/.* ([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' || true)
  if [ -z "$version" ]; then
    warn "Could not resolve the Codex version; keeping AGENTS.md guidance only"
    return 0
  fi
  set -- $version
  if [ "${1:-0}" -eq 0 ] && [ "${2:-0}" -lt 138 ]; then
    warn "Codex 0.138.0+ is required for project permission profiles; keeping AGENTS.md guidance only"
    return 0
  fi

  mkdir -p "$config_dir"

  # Only roots the active mode keeps read-only appear in the filesystem
  # profile; anything the mode makes editable inherits the ":workspace"
  # default. See lib/source-policy.sh.
  local codex_read_roots=""
  local _root _kind
  while IFS=$'\t' read -r _root _kind; do
    [ -n "$_root" ] || continue
    codex_read_roots="${codex_read_roots}${_root}"$'\n'
  done < <(source_policy_read_only_roots)

  if ! CODEX_READ_ROOTS="$codex_read_roots" python3 - "$config_file" "$CODEX_PERMISSION_START" "$CODEX_PERMISSION_END" <<'PY'
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
start, end = sys.argv[2], sys.argv[3]
read_roots = [line for line in os.environ.get("CODEX_READ_ROOTS", "").splitlines() if line.strip()]
content = path.read_text(encoding="utf-8") if path.exists() else ""
pattern = re.compile(rf"^\s*{re.escape(start)}$.*?^\s*{re.escape(end)}\s*$", re.MULTILINE | re.DOTALL)
unmanaged = pattern.sub("", content)
if re.search(r"^\s*(default_permissions|sandbox_mode)\s*=", unmanaged, re.MULTILINE) or re.search(
    r"^\s*\[sandbox_workspace_write(?:\.|\])", unmanaged, re.MULTILINE
):
    raise SystemExit("existing Codex default_permissions or sandbox_mode conflicts with managed WordPress permissions")

filesystem = "\n".join(f'"{root}" = "read"' for root in read_roots)

block = f'''{start}
default_permissions = "wp-coding-agents-wordpress"

[permissions.wp-coding-agents-wordpress]
extends = ":workspace"

[permissions.wp-coding-agents-wordpress.filesystem.":workspace_roots"]
{filesystem}
{end}'''

before = unmanaged.rstrip()
path.write_text((before + "\n\n" if before else "") + block + "\n", encoding="utf-8")
PY
  then
    warn "Existing Codex sandbox/default permissions conflict with managed WordPress permissions; keeping AGENTS.md guidance only"
    return 0
  fi
  service_file_normalize_perms "$config_file"
  config_after="$(cksum "$config_file" 2>/dev/null || true)"
  if [ "$config_before" != "$config_after" ] && [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("Codex permission profile")
  fi
  log "Configured Codex permission profile: installed WordPress source is read-only"
}

runtime_install_hooks() {
  return 0
}

runtime_generate_instructions() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
    log "Phase 8: AGENTS.md already exists — preserving file and syncing Codex override"
    _codex_sync_override
    return
  fi

  log "Phase 8: Generating AGENTS.md..."

  # Compose from Data Machine's SectionRegistry. DM is mandatory, and Codex
  # loads AGENTS.md directly from the working directory.
  if [ "$DRY_RUN" = false ]; then
    sync_homeboy_availability
    if wp_cmd datamachine memory compose AGENTS.md 2>/dev/null; then
      service_file_normalize_perms "$SITE_PATH/AGENTS.md"
      log "AGENTS.md composed from SectionRegistry"
      _codex_sync_override
      return
    fi
    warn "Compose failed — falling back to static template"
  fi

  local agents_tmpl="$SCRIPT_DIR/workspace/AGENTS.md"
  if [ ! -f "$agents_tmpl" ]; then
    error "AGENTS.md template not found at $agents_tmpl"
  fi

  local wp_cli_display="wp"
  if [ "$IS_STUDIO" = true ]; then
    wp_cli_display="studio wp"
  elif [ "$LOCAL_MODE" = false ]; then
    wp_cli_display="wp $WP_ROOT_FLAG --path=$SITE_PATH"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would generate AGENTS.md from template"
    _codex_sync_override
  else
    local agents_md
    agents_md=$(sed "s|{{WP_CLI_CMD}}|$wp_cli_display|g" "$agents_tmpl")
    write_file "$SITE_PATH/AGENTS.md" "$agents_md"
    service_file_normalize_perms "$SITE_PATH/AGENTS.md"
    _codex_sync_override
  fi
}

runtime_sync_instructions() {
  runtime_discover_dm_paths
  _codex_sync_override
}

_codex_sync_override() {
  local agents_md="$SITE_PATH/AGENTS.md"
  local codex_agents_md="$SITE_PATH/AGENTS.override.md"

  if [ -z "${DM_AGENT_FILES:-}" ]; then
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would sync Codex AGENTS.override.md from $agents_md plus Data Machine memory"
    return 0
  fi

  if [ ! -f "$agents_md" ]; then
    warn "Codex base AGENTS.md not found at $agents_md — skipping AGENTS.override.md sync"
    return 0
  fi

  if [ -f "$codex_agents_md" ] && ! grep -Fq "$CODEX_MANAGED_OVERRIDE_START" "$codex_agents_md"; then
    warn "Codex AGENTS.override.md already exists and is not managed by wp-coding-agents — leaving it untouched"
    return 0
  fi

  _codex_remove_legacy_agents_memory_block

  local memory_list
  memory_list=$(mktemp)
  printf '%s\n' "$DM_AGENT_FILES" > "$memory_list"

  CODEX_MANAGED_OVERRIDE_START="$CODEX_MANAGED_OVERRIDE_START" \
  CODEX_MANAGED_OVERRIDE_END="$CODEX_MANAGED_OVERRIDE_END" \
  CODEX_DM_MEMORY_START="$CODEX_DM_MEMORY_START" \
  CODEX_DM_MEMORY_END="$CODEX_DM_MEMORY_END" \
  python3 - "$agents_md" "$codex_agents_md" "$SITE_PATH" "$memory_list" <<'PY'
import os
import sys
from pathlib import Path

agents_path = Path(sys.argv[1])
override_path = Path(sys.argv[2])
site_path = Path(sys.argv[3])
list_path = Path(sys.argv[4])
override_start = os.environ["CODEX_MANAGED_OVERRIDE_START"]
override_end = os.environ["CODEX_MANAGED_OVERRIDE_END"]
memory_start = os.environ["CODEX_DM_MEMORY_START"]
memory_end = os.environ["CODEX_DM_MEMORY_END"]

base = agents_path.read_text(encoding="utf-8").rstrip()
paths = [line.strip() for line in list_path.read_text(encoding="utf-8").splitlines() if line.strip()]

sections = [
    override_start,
    "<!-- Generated from AGENTS.md plus Data Machine memory for Codex. -->",
    "<!-- Do not edit this file by hand; edit AGENTS.md or Data Machine memory and rerun setup/upgrade. -->",
    "",
    base,
    "",
    memory_start,
    "## Data Machine Memory",
    "",
    "Codex reads this managed section from the local WordPress site's Data Machine memory files.",
]

for raw_path in paths:
    path = Path(raw_path).expanduser()
    display_path = raw_path
    if not path.is_absolute():
        path = site_path / raw_path
        display_path = raw_path
    try:
        content = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        sections.extend(["", f"### Source: `{display_path}`", "", "_File not found at sync time._"])
        continue

    sections.extend(["", f"### Source: `{display_path}`", "", content.rstrip()])

sections.extend(["", memory_end, override_end])
updated = "\n".join(sections).rstrip() + "\n"

override_path.write_text(updated, encoding="utf-8")
PY
  rm -f "$memory_list"
  log "Synced Codex AGENTS.override.md from AGENTS.md plus Data Machine memory"
}

_codex_remove_legacy_agents_memory_block() {
  local agents_md="$SITE_PATH/AGENTS.md"

  if [ ! -f "$agents_md" ] || ! grep -Fq "$CODEX_DM_MEMORY_START" "$agents_md"; then
    return 0
  fi

  CODEX_DM_MEMORY_START="$CODEX_DM_MEMORY_START" \
  CODEX_DM_MEMORY_END="$CODEX_DM_MEMORY_END" \
  python3 - "$agents_md" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
start = os.environ["CODEX_DM_MEMORY_START"]
end = os.environ["CODEX_DM_MEMORY_END"]
content = path.read_text(encoding="utf-8")

if start not in content or end not in content:
    raise SystemExit(0)

before = content.split(start, 1)[0].rstrip()
after = content.split(end, 1)[1].lstrip()
parts = [part for part in (before, after.rstrip()) if part]
path.write_text("\n\n".join(parts).rstrip() + "\n", encoding="utf-8")
PY
  log "Removed legacy Codex memory block from shared AGENTS.md"
}

runtime_merge_mcp_servers() {
  if [ -z "${MCP_SERVERS:-}" ]; then
    return 0
  fi

  warn "MCP_SERVERS auto-merge is not supported for Codex yet; configure Codex MCP with 'codex mcp add'."
}

runtime_skills_dir() {
  echo "$SITE_PATH/.agents/skills"
}

runtime_skill_discovery_dirs() {
  runtime_skills_dir
}

runtime_start_cmd() {
  echo "cd $SITE_PATH && codex"
}

runtime_print_summary() {
  echo "Codex:"
  echo "  Config:   $SITE_PATH/AGENTS.override.md"
  echo "  Base:     $SITE_PATH/AGENTS.md"
  echo "  Skills:   $(runtime_skills_dir)"
  echo ""
}
