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

      # Scaffold SOUL.md
      log "Scaffolding SOUL.md..."
      SOUL_CONTENT="# Agent Soul — ${AGENT_SLUG}

## Identity
I am ${AGENT_NAME} — an AI agent managing ${SITE_DOMAIN}. I operate on this WordPress site via WP-CLI and Data Machine.

## Voice & Tone
Be genuinely helpful. Skip filler. Be resourceful — read the file, check the context, search for it, then ask if stuck.

## Rules
- Private things stay private
- When in doubt, ask before acting externally
- Git for everything — no uncommitted work
- Root cause over symptoms — fix the real problem
- Stop when stuck — pause after 2-3 failures, ask for guidance
- NEVER deploy without being told to

## Context
I manage ${SITE_DOMAIN} — a WordPress site with Data Machine for persistent memory, scheduling, and AI tools."

      # shellcheck disable=SC2086
      $WP_CMD datamachine agent files write SOUL.md \
        --agent="$AGENT_SLUG" --content="$SOUL_CONTENT" $WP_ROOT_FLAG --path="$SITE_PATH"

      # Scaffold MEMORY.md
      log "Scaffolding MEMORY.md..."
      MEMORY_CONTENT="# Agent Memory — ${AGENT_SLUG}

## Operational Notes
- Agent created during wp-coding-agents setup on $(date +%Y-%m-%d)"

      # shellcheck disable=SC2086
      $WP_CMD datamachine agent files write MEMORY.md \
        --agent="$AGENT_SLUG" --content="$MEMORY_CONTENT" $WP_ROOT_FLAG --path="$SITE_PATH"

      log "Agent '$AGENT_SLUG' created with SOUL.md and MEMORY.md"
    else
      log "Agent '$AGENT_SLUG' already exists — skipping creation"
    fi
  else
    log "Dry-run: would create agent '$AGENT_SLUG' with SOUL.md and MEMORY.md"
  fi
}
