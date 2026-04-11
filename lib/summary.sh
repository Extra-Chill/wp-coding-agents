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
  if [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ] && [ "$PLATFORM" = "mac" ]; then
    if [ -n "$KIMAKI_BOT_TOKEN" ]; then
      echo "  Kimaki (launchd service):"
      echo "    Start:  launchctl kickstart gui/$(id -u)/com.extrachill.kimaki"
      echo "    Stop:   launchctl kill SIGTERM gui/$(id -u)/com.extrachill.kimaki"
    else
      echo "  Kimaki setup:"
      echo "    1. Run onboarding:  cd $SITE_PATH && kimaki"
      echo "    2. Enable service:  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.extrachill.kimaki.plist"
    fi
    echo "    Logs:   tail -f $KIMAKI_DATA_DIR/kimaki.log"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "cc-connect" ] && [ "$PLATFORM" = "mac" ]; then
    echo "  cc-connect (launchd service):"
    echo "    Start:  launchctl kickstart gui/$(id -u)/com.extrachill.cc-connect"
    echo "    Stop:   launchctl kill SIGTERM gui/$(id -u)/com.extrachill.cc-connect"
    echo "    Logs:   tail -f ${CC_DATA_DIR:-$SERVICE_HOME/.cc-connect}/cc-connect.log"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "telegram" ] && [ "$PLATFORM" = "mac" ]; then
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
      echo "  Telegram (launchd services):"
      echo "    Start:  launchctl kickstart gui/$(id -u)/com.extrachill.opencode-serve"
      echo "            launchctl kickstart gui/$(id -u)/com.extrachill.opencode-telegram"
      echo "    Stop:   launchctl kill SIGTERM gui/$(id -u)/com.extrachill.opencode-serve"
      echo "            launchctl kill SIGTERM gui/$(id -u)/com.extrachill.opencode-telegram"
    else
      echo "  Telegram setup:"
      echo "    1. Add tokens to $SERVICE_HOME/.config/opencode-telegram-bot/.env"
      echo "    2. Enable services:"
      echo "       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.extrachill.opencode-serve.plist"
      echo "       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.extrachill.opencode-telegram.plist"
    fi
    echo "    Logs:   tail -f $SERVICE_HOME/.config/opencode-telegram-bot/opencode-serve.log"
    echo "            tail -f $SERVICE_HOME/.config/opencode-telegram-bot/opencode-telegram.log"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
    echo "  Start your agent:"
    echo "    cd $SITE_PATH && kimaki"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "telegram" ]; then
    echo "  Start your agent:"
    echo "    cd $SITE_PATH && opencode serve &"
    echo "    opencode-telegram start"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "cc-connect" ]; then
    echo "  Start your agent:"
    echo "    cd $SITE_PATH && cc-connect"
    echo ""
  else
    echo "  Start your agent:"
    if [ "$RUNTIME" = "claude-code" ]; then
      echo "    cd $SITE_PATH && claude"
    else
      echo "    cd $SITE_PATH && opencode"
    fi
    echo ""
  fi
}

_print_vps_next_steps() {
  if [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
    if [ -n "$KIMAKI_BOT_TOKEN" ]; then
      echo "  Bot token configured via KIMAKI_BOT_TOKEN."
      echo "  Start the agent:  systemctl start kimaki"
    else
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
    fi
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "cc-connect" ]; then
    echo "  Start the agent:  systemctl start cc-connect"
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "telegram" ]; then
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
      echo "  Telegram credentials configured. Start the agent:"
      echo "    systemctl start opencode-serve"
      echo "    systemctl start opencode-telegram"
    else
      echo "  1. Get your Telegram credentials:"
      echo "     - Bot token: message @BotFather → /newbot"
      echo "     - Your user ID: message @userinfobot"
      echo ""
      echo "  2. Add credentials to the bot config:"
      echo "     Edit $SERVICE_HOME/.config/opencode-telegram-bot/.env"
      echo "     Set TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USER_ID"
      echo ""
      echo "  3. Start the agent:"
      echo "     systemctl start opencode-serve"
      echo "     systemctl start opencode-telegram"
    fi
  else
    echo "  No chat bridge installed. Run your agent manually:"
    if [ "$RUNTIME" = "claude-code" ]; then
      echo "    cd $SITE_PATH && claude"
    else
      echo "    cd $SITE_PATH && opencode"
    fi
  fi
  echo ""
}
