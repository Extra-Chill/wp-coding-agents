#!/bin/bash
# Data Machine: plugin installation, agent creation, SOUL/MEMORY scaffold

install_data_machine() {
  log "Phase 4: Installing Data Machine..."
  install_plugin data-machine https://github.com/Extra-Chill/data-machine.git

  if [ "$MULTISITE" = true ]; then
    log "Data Machine activated on main site. Activate on subsites with:"
    log "  $(wp_cli_transport_display) plugin activate data-machine --url=subsite.$SITE_DOMAIN $WP_ROOT_FLAG"
  fi

  set_compose_agents_md_constant
}

# Write the DATAMACHINE_COMPOSE_AGENTS_MD gate to wp-config.php.
#
# This boolean constant turns ON core-owned AGENTS.md composition in Data
# Machine (see data-machine#2640). wp-coding-agents is the rightful writer
# because its presence is the signal that an external coding agent lives here —
# installs without one stay default-OFF and emit zero AGENTS.md noise.
#
# Uses an idempotent grep-guard and respects DRY_RUN / IS_STUDIO / wp-config.php
# existence. Written as a raw
# boolean (true) via --raw so the define is `define( ..., true )`, not the
# string "true". Safe to (re-)run on both setup and upgrade; harmless even if
# core does not yet read the constant.
set_compose_agents_md_constant() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ] && [ "$IS_STUDIO" = false ]; then
    if ! grep -q 'DATAMACHINE_COMPOSE_AGENTS_MD' "$SITE_PATH/wp-config.php"; then
      wp_cmd config set DATAMACHINE_COMPOSE_AGENTS_MD true --raw --type=constant
      log "Set DATAMACHINE_COMPOSE_AGENTS_MD to true"
    else
      log "DATAMACHINE_COMPOSE_AGENTS_MD already defined in wp-config.php"
    fi
  elif [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $(wp_cli_transport_display) config set DATAMACHINE_COMPOSE_AGENTS_MD true --raw --type=constant"
  fi
}

upgrade_data_machine_plugins() {
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    log "Phase 2: Skipping Data Machine plugins (--no-data-machine)"
    return
  fi

  log "Phase 2: Updating Data Machine plugins to latest tagged releases..."
  local status=0
  if [ "${PLUGINS_ONLY:-false}" = true ] && [ ! -d "$SITE_PATH/wp-content/plugins/data-machine" ]; then
    log "[data-machine] terminal=skipped reason=not-installed"
  else
    plugin_update_execute data-machine update_plugin_to_latest_tag data-machine https://github.com/Extra-Chill/data-machine.git || status=$PLUGIN_UPDATE_EXIT_PARTIAL
  fi

  return "$status"
}

# Derive a Data Machine agent slug from a site domain. Shared by setup
# (create_dm_agent) and upgrade (claude-code runtime sync) so both compute the
# same canonical slug: first domain label, lowercased, underscores → hyphens.
derive_agent_slug() {
  echo "$1" | sed 's/\..*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

create_dm_agent() {
  log "Phase 4.5: Creating Data Machine agent..."

  # Derive agent slug from domain
  if [ -z "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG=$(derive_agent_slug "$SITE_DOMAIN")
  fi

  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_NAME="${AGENT_NAME:-$(wp_cmd option get blogname 2>/dev/null || echo "$AGENT_SLUG")}"

    # Check if agent already exists (idempotent for re-runs)
    EXISTING_AGENT=$(wp_cmd datamachine agents show "$AGENT_SLUG" --format=json 2>/dev/null || echo "")

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

# NOTE: homeboy_project_id() is defined once, in lib/homeboy.sh, which is
# sourced after this file. A duplicate definition used to live here and was
# silently shadowed by the homeboy.sh copy (see #170) — keep it single-sourced.
