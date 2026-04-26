#!/bin/bash
# bridges/telegram.sh — Telegram chat bridge (opencode-telegram-bot).
#
# Two-service bridge: opencode serves the agent over HTTP on localhost:4096,
# opencode-telegram-bot relays messages between Telegram and that HTTP API.
# Both services ship as systemd units (VPS) or launchd plists (macOS) and are
# wired together via Requires= / startup ordering.

# ============================================================================
# Identity
# ============================================================================

bridge_systemd_units()  { echo "opencode-serve.service opencode-telegram.service"; }
bridge_launchd_labels() { echo "com.wp.opencode-serve com.wp.opencode-telegram"; }
bridge_binaries()       { echo "opencode-telegram opencode"; }
bridge_display_name()   { echo "telegram stack"; }
bridge_display_title()  { echo "Telegram"; }

bridge_is_ready() {
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]
}

# ============================================================================
# Install (setup-time)
# ============================================================================

bridge_install() {
  if ! command -v opencode-telegram &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g @grinev/opencode-telegram-bot
  else
    log "opencode-telegram already installed: $(opencode-telegram --version 2>/dev/null | head -1)"
  fi

  if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    warn "TELEGRAM_BOT_TOKEN not set — service will fail to start until you add it."
    warn "  Edit $SERVICE_HOME/.config/opencode-telegram-bot/.env after setup."
  fi
  if [ -z "$TELEGRAM_ALLOWED_USER_ID" ]; then
    warn "TELEGRAM_ALLOWED_USER_ID not set — service will fail to start until you add it."
    warn "  Get your ID from @userinfobot on Telegram, then edit the .env file."
  fi

  # Find binaries
  if [ "$DRY_RUN" = true ]; then
    if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
      TELEGRAM_BIN="/opt/homebrew/bin/opencode-telegram"
      OPENCODE_BIN="/opt/homebrew/bin/opencode"
    else
      TELEGRAM_BIN="/usr/bin/opencode-telegram"
      OPENCODE_BIN="/usr/bin/opencode"
    fi
  else
    TELEGRAM_BIN=$(which opencode-telegram 2>/dev/null || echo "/usr/bin/opencode-telegram")
    OPENCODE_BIN=$(which opencode 2>/dev/null || echo "/usr/bin/opencode")
  fi

  # opencode-serve env file
  SERVE_ENV_FILE="$SERVICE_HOME/.config/opencode-serve.env"
  run_cmd mkdir -p "$SERVICE_HOME/.config"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write opencode-serve config to $SERVE_ENV_FILE"
  else
    {
      [ -n "$OPENCODE_MODEL" ] && echo "OPENCODE_MODEL=$OPENCODE_MODEL"
      true
    } > "$SERVE_ENV_FILE"
    chmod 600 "$SERVE_ENV_FILE"
    if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
      chown "$SERVICE_USER:$SERVICE_USER" "$SERVE_ENV_FILE"
    fi
  fi

  # Telegram bot .env file
  TELEGRAM_CONFIG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"
  run_cmd mkdir -p "$TELEGRAM_CONFIG_DIR"
  if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
    run_cmd chown -R "$SERVICE_USER:$SERVICE_USER" "$TELEGRAM_CONFIG_DIR"
  fi

  TELEGRAM_ENV_CONTENT="TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_ALLOWED_USER_ID=${TELEGRAM_ALLOWED_USER_ID:-}
OPENCODE_API_URL=http://localhost:4096
OPENCODE_MODEL_PROVIDER=${OPENCODE_MODEL_PROVIDER:-opencode}
OPENCODE_MODEL_ID=${OPENCODE_MODEL_ID:-big-pickle}
LOG_LEVEL=info"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write Telegram bot config to $TELEGRAM_CONFIG_DIR/.env"
  else
    echo "$TELEGRAM_ENV_CONTENT" > "$TELEGRAM_CONFIG_DIR/.env"
    chmod 600 "$TELEGRAM_CONFIG_DIR/.env"
    if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
      chown "$SERVICE_USER:$SERVICE_USER" "$TELEGRAM_CONFIG_DIR/.env"
    fi
  fi

  if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    _telegram_install_launchd
  elif [ "$LOCAL_MODE" = true ]; then
    log "Local mode: Telegram bot installed. Run manually with:"
    log "  cd $SITE_PATH && opencode serve &"
    log "  opencode-telegram start"
  else
    _telegram_install_systemd
  fi
}

_telegram_install_launchd() {
  SERVE_PLIST_LABEL="com.wp.opencode-serve"
  TELEGRAM_PLIST_LABEL="com.wp.opencode-telegram"
  PLIST_DIR="$HOME/Library/LaunchAgents"
  SERVE_PLIST="$PLIST_DIR/$SERVE_PLIST_LABEL.plist"
  TELEGRAM_PLIST="$PLIST_DIR/$TELEGRAM_PLIST_LABEL.plist"
  TELEGRAM_LOG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"

  run_cmd mkdir -p "$PLIST_DIR"

  write_file "$SERVE_PLIST" "$(bridge_render_launchd "$SERVE_PLIST_LABEL")"
  write_file "$TELEGRAM_PLIST" "$(bridge_render_launchd "$TELEGRAM_PLIST_LABEL")"

  if [ "$DRY_RUN" = false ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
    launchctl bootout "gui/$(id -u)" "$SERVE_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$SERVE_PLIST"
    launchctl bootout "gui/$(id -u)" "$TELEGRAM_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$TELEGRAM_PLIST"
    log "Telegram bot launchd services installed and started"
  elif [ "$DRY_RUN" = false ]; then
    log "Telegram credentials not set — services not started"
    log "Add tokens to $TELEGRAM_CONFIG_DIR/.env, then re-run setup or bootstrap manually:"
    log "  launchctl bootstrap gui/$(id -u) $SERVE_PLIST"
    log "  launchctl bootstrap gui/$(id -u) $TELEGRAM_PLIST"
  fi

  log "OpenCode serve: $SERVE_PLIST_LABEL"
  log "Telegram bot:   $TELEGRAM_PLIST_LABEL"
  log "  Start:  launchctl kickstart gui/$(id -u)/$SERVE_PLIST_LABEL"
  log "          launchctl kickstart gui/$(id -u)/$TELEGRAM_PLIST_LABEL"
  log "  Stop:   launchctl kill SIGTERM gui/$(id -u)/$SERVE_PLIST_LABEL"
  log "          launchctl kill SIGTERM gui/$(id -u)/$TELEGRAM_PLIST_LABEL"
  log "  Logs:   tail -f $TELEGRAM_LOG_DIR/opencode-serve.log"
  log "          tail -f $TELEGRAM_LOG_DIR/opencode-telegram.log"
}

_telegram_install_systemd() {
  local ENV_BLOCK="Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin"

  write_file "/etc/systemd/system/opencode-serve.service" \
    "$(bridge_render_systemd opencode-serve.service "$ENV_BLOCK")"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable opencode-serve

  write_file "/etc/systemd/system/opencode-telegram.service" \
    "$(bridge_render_systemd opencode-telegram.service "$ENV_BLOCK")"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable opencode-telegram
}

# ============================================================================
# Upgrade-time config sync (Phase 2)
# ============================================================================

bridge_sync_config() {
  log "Phase 2: telegram detected — no per-install artifacts to sync."
  if command -v opencode-telegram &>/dev/null; then
    local tg_version
    tg_version=$(opencode-telegram --version 2>/dev/null | head -1 || echo "unknown")
    log "  opencode-telegram version: $tg_version"
  else
    warn "  opencode-telegram binary not on PATH"
  fi
  if command -v opencode &>/dev/null; then
    local oc_version
    oc_version=$(opencode --version 2>/dev/null | head -1 || echo "unknown")
    log "  opencode version: $oc_version"
  else
    warn "  opencode binary not on PATH"
  fi
  log "  To update upstream:  npm update -g @grinev/opencode-telegram-bot"
  log "  User env files (never touched):"
  log "    \$HOME/.config/opencode-serve.env"
  log "    \$HOME/.config/opencode-telegram-bot/.env"
}

# ============================================================================
# Upgrade-time service refresh (Phase 5)
# ============================================================================

bridge_update_systemd() {
  log "Phase 5: Checking opencode-serve.service + opencode-telegram.service templates..."

  local SERVE_UNIT="/etc/systemd/system/opencode-serve.service"
  local TG_UNIT="/etc/systemd/system/opencode-telegram.service"

  local OPENCODE_BIN TELEGRAM_BIN SERVE_ENV_FILE TELEGRAM_CONFIG_DIR
  OPENCODE_BIN=$(which opencode 2>/dev/null || echo "/usr/bin/opencode")
  TELEGRAM_BIN=$(which opencode-telegram 2>/dev/null || echo "/usr/bin/opencode-telegram")
  SERVE_ENV_FILE="$SERVICE_HOME/.config/opencode-serve.env"
  TELEGRAM_CONFIG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"

  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin"

  # --- opencode-serve.service ---
  if [ -f "$SERVE_UNIT" ]; then
    local SERVE_CURRENT_ENV SERVE_MERGED_ENV SERVE_NEW
    SERVE_CURRENT_ENV=$(grep '^Environment=' "$SERVE_UNIT" || true)
    SERVE_MERGED_ENV=$(_merge_systemd_env_lines "$SERVE_CURRENT_ENV" "$TEMPLATE_ENV")
    SERVE_NEW=$(bridge_render_systemd opencode-serve.service "$SERVE_MERGED_ENV")
    _smart_update_systemd_unit "$SERVE_UNIT" "$SERVE_NEW" "opencode-serve.service"
  else
    warn "  $SERVE_UNIT does not exist — skipping"
  fi

  # --- opencode-telegram.service ---
  if [ -f "$TG_UNIT" ]; then
    local TG_CURRENT_ENV TG_MERGED_ENV TG_NEW
    TG_CURRENT_ENV=$(grep '^Environment=' "$TG_UNIT" || true)
    TG_MERGED_ENV=$(_merge_systemd_env_lines "$TG_CURRENT_ENV" "$TEMPLATE_ENV")
    TG_NEW=$(bridge_render_systemd opencode-telegram.service "$TG_MERGED_ENV")
    _smart_update_systemd_unit "$TG_UNIT" "$TG_NEW" "opencode-telegram.service"
  else
    warn "  $TG_UNIT does not exist — skipping"
  fi
}

# bridge_update_launchd: telegram doesn't refresh its plists on upgrade
# (no token-merge path comparable to kimaki's). Intentionally not defined.

# ============================================================================
# Templates: systemd unit + launchd plist
# ============================================================================

bridge_render_systemd() {
  local unit="$1" env_block="$2"
  case "$unit" in
    opencode-serve.service)
      cat <<EOF
[Unit]
Description=OpenCode Server (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
EnvironmentFile=-$SERVE_ENV_FILE
ExecStart=$OPENCODE_BIN serve
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
    opencode-telegram.service)
      cat <<EOF
[Unit]
Description=OpenCode Telegram Bot (wp-coding-agents)
After=network.target opencode-serve.service
Requires=opencode-serve.service

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
EnvironmentFile=$TELEGRAM_CONFIG_DIR/.env
ExecStart=$TELEGRAM_BIN start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
    *)
      echo "telegram has no unit '$unit'" >&2
      return 1 ;;
  esac
}

bridge_render_launchd() {
  local label="$1"
  local log_dir="$TELEGRAM_CONFIG_DIR"
  case "$label" in
    com.wp.opencode-serve)
      cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$OPENCODE_BIN</string>
        <string>serve</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/opencode-serve.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/opencode-serve.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>$(if [ -n "${OPENCODE_MODEL:-}" ]; then echo "
        <key>OPENCODE_MODEL</key>
        <string>$OPENCODE_MODEL</string>"; fi)
    </dict>
</dict>
</plist>
EOF
      ;;
    com.wp.opencode-telegram)
      cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TELEGRAM_BIN</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/opencode-telegram.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/opencode-telegram.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>$(if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "
        <key>TELEGRAM_BOT_TOKEN</key>
        <string>$TELEGRAM_BOT_TOKEN</string>"; fi)$(if [ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]; then echo "
        <key>TELEGRAM_ALLOWED_USER_ID</key>
        <string>$TELEGRAM_ALLOWED_USER_ID</string>"; fi)
        <key>OPENCODE_API_URL</key>
        <string>http://localhost:4096</string>
    </dict>
</dict>
</plist>
EOF
      ;;
    *)
      echo "telegram has no label '$label'" >&2
      return 1 ;;
  esac
}

# ============================================================================
# Human-facing command accessors
# ============================================================================

bridge_restart_cmd() {
  local env="$1" uid label
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in com.wp.opencode-serve com.wp.opencode-telegram; do
        echo "launchctl bootout gui/${uid} ~/Library/LaunchAgents/${label}.plist 2>/dev/null || true; launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/${label}.plist"
      done
      ;;
    local-manual)
      echo "cd $SITE_PATH && opencode serve &"
      echo "opencode-telegram start"
      ;;
    vps)
      echo "systemctl restart opencode-serve opencode-telegram"
      ;;
    *)
      echo "bridge_restart_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_verify_cmd() {
  local env="$1" uid label
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in com.wp.opencode-serve com.wp.opencode-telegram; do
        echo "launchctl print gui/${uid}/${label} | head -20"
      done
      ;;
    local-manual)
      echo "pgrep -fl opencode-telegram"
      ;;
    vps)
      echo "systemctl status opencode-serve opencode-telegram"
      ;;
    *)
      echo "bridge_verify_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_logs_cmd() {
  echo "tail -f $TELEGRAM_CONFIG_DIR/opencode-serve.log"
  echo "tail -f $TELEGRAM_CONFIG_DIR/opencode-telegram.log"
}

bridge_start_hint() {
  local env="$1" uid label
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in com.wp.opencode-serve com.wp.opencode-telegram; do
        echo "launchctl kickstart gui/${uid}/${label}"
      done
      ;;
    local-manual)
      bridge_restart_cmd local-manual
      ;;
    vps)
      echo "systemctl start opencode-serve opencode-telegram"
      ;;
    *)
      echo "bridge_start_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_stop_hint() {
  local env="$1" uid label
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in com.wp.opencode-serve com.wp.opencode-telegram; do
        echo "launchctl kill SIGTERM gui/${uid}/${label}"
      done
      ;;
    vps)
      echo "systemctl stop opencode-serve opencode-telegram"
      ;;
    local-manual)
      ;;
    *)
      echo "bridge_stop_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

# ============================================================================
# Summary blocks
# ============================================================================

# Onboarding prose for VPS when TELEGRAM_BOT_TOKEN / TELEGRAM_ALLOWED_USER_ID
# are missing.
bridge_vps_setup_block() {
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
}

# Onboarding prose for macOS launchd when credentials are missing.
bridge_launchd_setup_block() {
  local uid
  uid=$(id -u)
  echo "  Telegram setup:"
  echo "    1. Add tokens to $SERVICE_HOME/.config/opencode-telegram-bot/.env"
  echo "    2. Enable services:"
  echo "       launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/com.wp.opencode-serve.plist"
  echo "       launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/com.wp.opencode-telegram.plist"
}

# Optional preamble for VPS start-block when creds ARE configured.
bridge_vps_start_preamble() {
  echo "  Telegram credentials configured. Start the agent:"
}

# Verify-block addendum printed by upgrade.sh after the standard status line.
bridge_verify_extra() {
  echo "opencode-telegram --version   # binary version"
}
