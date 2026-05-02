#!/bin/bash
# Data Machine: plugin installation, agent creation, SOUL/MEMORY scaffold

install_data_machine() {
  log "Phase 4: Installing Data Machine..."
  install_plugin data-machine https://github.com/Extra-Chill/data-machine.git

  if [ "$MULTISITE" = true ]; then
    log "Data Machine activated on main site. Activate on subsites with:"
    log "  $WP_CMD plugin activate data-machine --url=subsite.$SITE_DOMAIN $WP_ROOT_FLAG"
  fi

  log "Installing Data Machine Code (developer tools)..."
  install_plugin data-machine-code https://github.com/Extra-Chill/data-machine-code.git

  # Set workspace path in wp-config.php if not already defined
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ] && [ "$IS_STUDIO" = false ]; then
    if ! grep -q 'DATAMACHINE_WORKSPACE_PATH' "$SITE_PATH/wp-config.php"; then
      wp_cmd config set DATAMACHINE_WORKSPACE_PATH "$DM_WORKSPACE_DIR" --type=constant
      log "Set DATAMACHINE_WORKSPACE_PATH to $DM_WORKSPACE_DIR"
    else
      log "DATAMACHINE_WORKSPACE_PATH already defined in wp-config.php"
    fi
  elif [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD config set DATAMACHINE_WORKSPACE_PATH $DM_WORKSPACE_DIR --type=constant"
  fi
}

upgrade_data_machine_plugins() {
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    log "Phase 2: Skipping Data Machine plugins (--no-data-machine)"
    return
  fi

  log "Phase 2: Updating Data Machine plugins to latest tagged releases..."
  update_plugin_to_latest_tag data-machine https://github.com/Extra-Chill/data-machine.git
  update_plugin_to_latest_tag data-machine-code https://github.com/Extra-Chill/data-machine-code.git
}

create_dm_agent() {
  log "Phase 4.5: Creating Data Machine agent..."

  # Derive agent slug from domain
  if [ -z "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG=$(echo "$SITE_DOMAIN" | sed 's/\..*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  fi

  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    # shellcheck disable=SC2086
    AGENT_NAME="${AGENT_NAME:-$($WP_CMD option get blogname $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || echo "$AGENT_SLUG")}"

    # Check if agent already exists (idempotent for re-runs)
    # shellcheck disable=SC2086
    EXISTING_AGENT=$($WP_CMD datamachine agents show "$AGENT_SLUG" --format=json $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || echo "")

    if [ -z "$EXISTING_AGENT" ]; then
      log "Creating agent: $AGENT_SLUG ($AGENT_NAME)"
      wp_cmd datamachine agents create "$AGENT_SLUG" \
        --name="$AGENT_NAME" \
        --owner=1

      log "Agent '$AGENT_SLUG' created. SOUL.md and MEMORY.md seeded by Data Machine with sensible defaults — customize via 'wp datamachine memory write' or by editing the files directly."
    else
      log "Agent '$AGENT_SLUG' already exists — skipping creation"
    fi
  else
    log "Dry-run: would create agent '$AGENT_SLUG' with SOUL.md and MEMORY.md"
  fi
}

sync_homeboy_availability() {
  local homeboy_available=false

  if command -v homeboy >/dev/null 2>&1; then
    homeboy_available=true
  fi

  if [ "$DRY_RUN" = true ]; then
    if [ "$homeboy_available" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update datamachine_code_homeboy_available 1"
    else
      echo -e "${BLUE}[dry-run]${NC} $WP_CMD option delete datamachine_code_homeboy_available"
    fi
    sync_homeboy_project_components
    return 0
  fi

  if [ "$homeboy_available" = true ]; then
    wp_cmd option update datamachine_code_homeboy_available 1 >/dev/null 2>&1 || \
      warn "Could not record Homeboy availability for AGENTS.md compose"
    sync_homeboy_project_components
  else
    wp_cmd option delete datamachine_code_homeboy_available >/dev/null 2>&1 || true
  fi
}

discover_dm_workspace_dir() {
  if [ -n "${DATAMACHINE_WORKSPACE_PATH:-}" ]; then
    DM_WORKSPACE_DIR="$DATAMACHINE_WORKSPACE_PATH"
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ] || [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi

  local workspace_path
  workspace_path=$(wp_cmd datamachine-code workspace path 2>/dev/null || true)
  if [ -n "$workspace_path" ]; then
    DM_WORKSPACE_DIR="$workspace_path"
  fi
}

homeboy_project_id() {
  if [ -n "${HOMEBOY_PROJECT_ID:-}" ]; then
    printf '%s\n' "$HOMEBOY_PROJECT_ID"
    return 0
  fi

  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/homeboy.json" ]; then
    return 1
  fi

  python3 - "$SITE_PATH/homeboy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    project_id = json.load(handle).get("id", "")

if project_id:
    print(project_id)
PY
}

sync_homeboy_project_components() {
  if ! command -v homeboy >/dev/null 2>&1; then
    return 0
  fi

  discover_dm_workspace_dir

  local project_id
  if ! project_id=$(homeboy_project_id); then
    warn "Homeboy project config not found at site root — skipping DMC component attachment"
    return 0
  fi

  if [ -z "${DM_WORKSPACE_DIR:-}" ]; then
    warn "DMC workspace path not configured — skipping Homeboy component attachment"
    return 0
  fi

  if [ ! -d "$DM_WORKSPACE_DIR" ]; then
    warn "DMC workspace path does not exist ($DM_WORKSPACE_DIR) — skipping Homeboy component attachment"
    return 0
  fi

  log "Attaching Homeboy components from DMC workspace: $DM_WORKSPACE_DIR"

  local attached=0
  local skipped=0
  local failed=0
  local repo_path repo_name

  shopt -s nullglob
  for repo_path in "$DM_WORKSPACE_DIR"/*; do
    [ -d "$repo_path" ] || continue
    repo_name=$(basename "$repo_path")

    if [ -n "${SITE_PATH:-}" ] && [ "$repo_path" = "$SITE_PATH" ]; then
      log "  skipped $repo_name: site project root"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$repo_name" == *"@"* ]]; then
      log "  skipped $repo_name: worktree skipped"
      skipped=$((skipped + 1))
      continue
    fi

    if [ ! -f "$repo_path/homeboy.json" ]; then
      log "  skipped $repo_name: no homeboy.json"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} homeboy project components attach-path $project_id $repo_path"
      attached=$((attached + 1))
      continue
    fi

    if homeboy project components attach-path "$project_id" "$repo_path" >/dev/null; then
      log "  attached $repo_name"
      attached=$((attached + 1))
    else
      warn "  failed $repo_name: homeboy attach-path failed"
      failed=$((failed + 1))
    fi
  done
  shopt -u nullglob

  log "Homeboy component sync complete: $attached attached, $skipped skipped, $failed failed"
}
