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
  if [ "$INSTALL_DATA_MACHINE" = true ]; then
    echo "Data Machine:"
    if [ -n "$AGENT_SLUG" ]; then
      echo "  Agent:       $AGENT_SLUG"
    fi
    echo "  Discover:    $WP_CMD datamachine agent paths${AGENT_SLUG:+ --agent=$AGENT_SLUG} $WP_ROOT_FLAG"
    echo "  Code tools:  data-machine-code (workspace, GitHub, git)"
    echo "  Workspace:   $DM_WORKSPACE_DIR (created on first use)"
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
DATA_MACHINE=$INSTALL_DATA_MACHINE
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

  if [ "$INSTALL_DATA_MACHINE" = true ]; then
    echo "  Configure Data Machine:"
    echo "    - Set AI provider API keys in WP Admin → Data Machine → Settings"
    if [ "$LOCAL_MODE" = false ]; then
      echo "    - Or via WP-CLI: $WP_CMD datamachine settings --allow-root"
    else
      echo "    - Or via WP-CLI: $WP_CMD datamachine settings --path=$SITE_PATH"
    fi
    echo ""
  fi

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
  if [ "$env" = "local-launchd" ] && bridge_is_ready "$CHAT_BRIDGE"; then
    _print_launchd_run_block "$CHAT_BRIDGE"
    return
  fi

  # macOS launchd without creds: bridge-specific setup prose.
  if [ "$env" = "local-launchd" ]; then
    _print_launchd_setup_block "$CHAT_BRIDGE"
    return
  fi

  # Local-manual (Linux local, no launchd): plain start command.
  echo "  Start your agent:"
  local cmd
  while IFS= read -r cmd; do
    echo "    $cmd"
  done < <(bridge_start_hint "$CHAT_BRIDGE" local-manual)
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
  if bridge_is_ready "$CHAT_BRIDGE"; then
    local cmd units
    # Bridge-specific preamble — matches longstanding prose.
    case "$CHAT_BRIDGE" in
      kimaki)   echo "  Bot token configured via KIMAKI_BOT_TOKEN." ;;
      telegram) echo "  Telegram credentials configured. Start the agent:" ;;
    esac
    units=$(bridge_systemd_units "$CHAT_BRIDGE" | wc -w | tr -d ' ')
    if [ "$units" -gt 1 ]; then
      # Multi-service bridge: list each service start on its own line.
      for unit in $(bridge_systemd_units "$CHAT_BRIDGE"); do
        echo "    systemctl start ${unit%.service}"
      done
    else
      cmd=$(bridge_start_hint "$CHAT_BRIDGE" vps)
      echo "  Start the agent:  $cmd"
    fi
    echo ""
    return
  fi

  # Credentials missing: bridge-specific VPS onboarding.
  _print_vps_setup_block "$CHAT_BRIDGE"
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
  local bridge="$1" display units_label
  display=$(bridge_display_title "$bridge")
  if [ "$(bridge_launchd_labels "$bridge" | wc -w | tr -d ' ')" -gt 1 ]; then
    units_label="launchd services"
  else
    units_label="launchd service"
  fi
  echo "  $display ($units_label):"
  _print_labelled_lines "    Start:  " bridge_start_hint "$bridge" local-launchd
  _print_labelled_lines "    Stop:   " bridge_stop_hint  "$bridge" local-launchd
  _print_labelled_lines "    Logs:   " bridge_logs_cmd   "$bridge"
  echo ""
}

# Bridge-specific onboarding prose for macOS launchd when credentials are
# missing. cc-connect is always "ready" (no token) so it never reaches here.
_print_launchd_setup_block() {
  local bridge="$1" uid
  uid=$(id -u)
  case "$bridge" in
    kimaki)
      echo "  Kimaki setup:"
      echo "    1. Run onboarding:  cd $SITE_PATH && kimaki"
      echo "    2. Enable service:  launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/com.wp.kimaki.plist"
      ;;
    telegram)
      echo "  Telegram setup:"
      echo "    1. Add tokens to $SERVICE_HOME/.config/opencode-telegram-bot/.env"
      echo "    2. Enable services:"
      for label in $(bridge_launchd_labels telegram); do
        echo "       launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/${label}.plist"
      done
      ;;
  esac
  _print_labelled_lines "    Logs:   " bridge_logs_cmd "$bridge"
  echo ""
}

# Bridge-specific onboarding prose for VPS when credentials are missing.
_print_vps_setup_block() {
  local bridge="$1"
  case "$bridge" in
    kimaki)
      echo "  1. Set up Discord bot token:"
      echo "     Option A: Run kimaki interactively first (sets up database)"
      if [ "$RUN_AS_ROOT" = false ]; then
        echo "       su - $SERVICE_USER -c 'cd $SITE_PATH && kimaki'"
      else
        echo "       cd $SITE_PATH && kimaki"
      fi
      echo "     Option B: Set KIMAKI_BOT_TOKEN in the systemd service"
      echo "       systemctl edit kimaki"
      echo "       [Service]"
      echo "       Environment=KIMAKI_BOT_TOKEN=your-token-here"
      echo ""
      echo "  2. Start the agent:  systemctl start kimaki"
      ;;
    telegram)
      echo "  1. Get your Telegram credentials:"
      echo "     - Bot token: message @BotFather → /newbot"
      echo "     - Your user ID: message @userinfobot"
      echo ""
      echo "  2. Add credentials to the bot config:"
      echo "     Edit $SERVICE_HOME/.config/opencode-telegram-bot/.env"
      echo "     Set TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USER_ID"
      echo ""
      echo "  3. Start the agent:"
      for unit in $(bridge_systemd_units telegram); do
        echo "     systemctl start ${unit%.service}"
      done
      ;;
  esac
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
