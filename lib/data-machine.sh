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
