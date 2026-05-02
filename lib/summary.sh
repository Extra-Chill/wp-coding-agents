#!/bin/bash
# Summary: output, credentials, next steps

print_summary() {
  echo ""
  echo "=============================================="
  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}wp-coding-agents dry-run complete!${NC}"
    echo "(No changes were made)"
  else
    echo -e "${GREEN}wp-coding-agents installation complete!${NC}"
  fi
  echo "=============================================="
  echo ""
  if [ "$LOCAL_MODE" = true ]; then
    echo "Platform:   Local ($OS)"
  fi
  echo "WordPress:"
  echo "  URL:      https://$SITE_DOMAIN"
  echo "  Admin:    https://$SITE_DOMAIN/wp-admin"
  echo "  Path:     $SITE_PATH"
  echo ""

  # Runtime-specific config summary
  runtime_print_summary

  if [ "$MULTISITE" = true ]; then
    echo "Multisite:"
    echo "  Type:        $MULTISITE_TYPE"
    echo ""
  fi
  echo "Data Machine:"
  if [ -n "$AGENT_SLUG" ]; then
    echo "  Agent:       $AGENT_SLUG"
  fi
  echo "  Discover:    $WP_CMD datamachine memory paths${AGENT_SLUG:+ --agent=$AGENT_SLUG} $WP_ROOT_FLAG"
  echo "  Code tools:  data-machine-code (workspace, GitHub, git)"
  echo "  Workspace:   $DM_WORKSPACE_DIR (created on first use)"
  echo ""
  if [ "${HOMEBOY_MODE:-auto}" != "disabled" ] && [ -n "${HOMEBOY_PROJECT_ID:-}" ]; then
    echo "Homeboy:"
    echo "  Project:     $HOMEBOY_PROJECT_ID"
    echo "  Site path:   $SITE_PATH"
    if [ -n "${HOMEBOY_SERVER_ID_RESOLVED:-}" ]; then
      echo "  Server:      $HOMEBOY_SERVER_ID_RESOLVED"
    fi
    echo "  Show:        homeboy project show $HOMEBOY_PROJECT_ID"
    echo ""
  fi
  echo "Agent:"
  if [ "$LOCAL_MODE" = true ]; then
    echo "  User:     $(whoami) (local)"
  elif [ "$RUN_AS_ROOT" = true ]; then
    echo "  User:     root"
  else
    echo "  User:     $SERVICE_USER (non-root)"
  fi
  echo "  Runtime:  $RUNTIME"
  if [ "$INSTALL_CHAT" = true ]; then
    echo "  Bridge:   $CHAT_BRIDGE"
  fi
  SKILLS_DIR="$(runtime_skills_dir)"
  if [ "$INSTALL_SKILLS" = true ]; then
    echo "  Skills:   $SKILLS_DIR"
  else
    echo "  Skills:   Skipped (--no-skills)"
  fi
  echo ""

  # Save credentials (VPS only)
  if [ "$LOCAL_MODE" = false ]; then
    CREDENTIALS_CONTENT="# wp-coding-agents credentials (keep this secure!)
# Generated: $(date)

SITE_DOMAIN=$SITE_DOMAIN
SITE_PATH=$SITE_PATH
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_PASS=$WP_ADMIN_PASS
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
AGENT_SLUG=$AGENT_SLUG
MULTISITE=$MULTISITE
MULTISITE_TYPE=$MULTISITE_TYPE
SERVICE_USER=$SERVICE_USER
RUNTIME=$RUNTIME
CHAT_BRIDGE=$CHAT_BRIDGE"

    CREDENTIALS_FILE="$SERVICE_HOME/.wp-coding-agents-credentials"
    write_file "$CREDENTIALS_FILE" "$CREDENTIALS_CONTENT"
    run_cmd chmod 600 "$CREDENTIALS_FILE"
    log "Credentials saved to $CREDENTIALS_FILE"
  fi

  _print_next_steps
}

_print_next_steps() {
  echo "=============================================="
  echo "Next steps"
  echo "=============================================="
  echo ""

  if [ "$LOCAL_MODE" = true ]; then
    _print_local_next_steps
  else
    _print_vps_next_steps
  fi

  echo "  Configure Data Machine:"
  echo "    - Set AI provider API keys in WP Admin → Data Machine → Settings"
  if [ "$LOCAL_MODE" = false ]; then
    echo "    - Or via WP-CLI: $WP_CMD datamachine settings --allow-root"
  else
    echo "    - Or via WP-CLI: $WP_CMD datamachine settings --path=$SITE_PATH"
  fi
  echo ""
}

_print_local_next_steps() {
  # No chat bridge installed — show the raw runtime CLI fallback.
  if [ "$INSTALL_CHAT" != true ] || [ -z "$CHAT_BRIDGE" ]; then
    _print_bare_runtime_start
    return
  fi

  local env
  if [ "$PLATFORM" = "mac" ]; then
    env="local-launchd"
  else
    env="local-manual"
  fi

  # macOS launchd with creds set: uniform Start/Stop/Logs block.
  if [ "$env" = "local-launchd" ] && bridge_is_ready; then
    _print_launchd_run_block
    return
  fi

  # macOS launchd without creds: bridge-specific setup prose. Bridges that
  # are always-ready (cc-connect) never reach this branch.
  if [ "$env" = "local-launchd" ]; then
    if bridge_has_hook launchd_setup_block; then
      bridge_launchd_setup_block
      _print_labelled_lines "    Logs:   " bridge_logs_cmd
      echo ""
    fi
    return
  fi

  # Local-manual (Linux local, no launchd): plain start command.
  echo "  Start your agent:"
  local cmd
  while IFS= read -r cmd; do
    echo "    $cmd"
  done < <(bridge_start_hint local-manual)
  echo ""
}

_print_vps_next_steps() {
  if [ "$INSTALL_CHAT" != true ] || [ -z "$CHAT_BRIDGE" ]; then
    echo "  No chat bridge installed. Run your agent manually:"
    _print_bare_runtime_cmd
    echo ""
    return
  fi

  # Credentials configured.
  if bridge_is_ready; then
    local cmd units unit
    # Optional bridge-specific preamble (e.g. "Bot token configured...").
    if bridge_has_hook vps_start_preamble; then
      bridge_vps_start_preamble
    fi
    units=$(bridge_systemd_units | wc -w | tr -d ' ')
    if [ "$units" -gt 1 ]; then
      # Multi-service bridge: list each service start on its own line.
      for unit in $(bridge_systemd_units); do
        echo "    systemctl start ${unit%.service}"
      done
    else
      cmd=$(bridge_start_hint vps)
      echo "  Start the agent:  $cmd"
    fi
    echo ""
    return
  fi

  # Credentials missing: bridge-specific VPS onboarding.
  if bridge_has_hook vps_setup_block; then
    bridge_vps_setup_block
  fi
  echo ""
}

# ----------------------------------------------------------------------------
# Presentation helpers
# ----------------------------------------------------------------------------

# Start/Stop/Logs block for macOS launchd when credentials are configured.
# Output shape:
#   <Display> (launchd service[s]):
#     Start:  <cmd>
#             <cmd>   (for multi-service bridges)
#     Stop:   <cmd>
#             <cmd>
#     Logs:   <cmd>
#             <cmd>
_print_launchd_run_block() {
  local display units_label
  display=$(bridge_display_title)
  if [ "$(bridge_launchd_labels | wc -w | tr -d ' ')" -gt 1 ]; then
    units_label="launchd services"
  else
    units_label="launchd service"
  fi
  echo "  $display ($units_label):"
  _print_labelled_lines "    Start:  " bridge_start_hint local-launchd
  _print_labelled_lines "    Stop:   " bridge_stop_hint  local-launchd
  _print_labelled_lines "    Logs:   " bridge_logs_cmd
  echo ""
}

# Run a command producing 1+ lines; print the first line prefixed with
# <label>, subsequent lines indented to the same column.
_print_labelled_lines() {
  local label="$1"; shift
  local pad
  pad=$(printf '%*s' "${#label}" '')
  local first=true line
  while IFS= read -r line; do
    if [ "$first" = true ]; then
      echo "${label}${line}"
      first=false
    else
      echo "${pad}${line}"
    fi
  done < <("$@")
}

# Raw-runtime fallback when no chat bridge is installed.
_print_bare_runtime_start() {
  echo "  Start your agent:"
  _print_bare_runtime_cmd
  echo ""
}
_print_bare_runtime_cmd() {
  if [ "$RUNTIME" = "claude-code" ]; then
    echo "    cd $SITE_PATH && claude"
  else
    echo "    cd $SITE_PATH && opencode"
  fi
}
