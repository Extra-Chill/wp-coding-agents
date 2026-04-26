#!/bin/bash
# bridges/kimaki.sh — Kimaki Discord bridge.
#
# Owns install (local launchd / VPS systemd / Linux-local manual), upgrade-time
# config sync (plugins, post-upgrade.sh, skills kill-list, regression test),
# systemd + launchd template rendering, summary blocks, and the per-bridge
# assets at bridges/kimaki/ (plugins/, post-upgrade.sh, skills-kill-list.txt).
#
# Install layout:
#   VPS:   /opt/kimaki-config/{plugins,post-upgrade.sh,skills-kill-list.txt}
#          + /etc/systemd/system/kimaki.service (ExecStartPre runs post-upgrade.sh)
#   Local: $(npm root -g)/kimaki/plugins for plugins (lives inside the npm
#          package; wiped on `npm update -g kimaki`),
#          $KIMAKI_DATA_DIR/kimaki-config/ for post-upgrade.sh + kill list
#          (executed inline at upgrade time — no launchd ExecStartPre hook),
#          + $HOME/Library/LaunchAgents/com.wp.kimaki.plist on macOS.

# ============================================================================
# Identity
# ============================================================================

bridge_systemd_units()  { echo "kimaki.service"; }
bridge_launchd_labels() { echo "com.wp.kimaki"; }
bridge_binaries()       { echo "kimaki"; }
bridge_display_name()   { echo "kimaki"; }
bridge_display_title()  { echo "Kimaki"; }

bridge_is_ready() {
  [ -n "${KIMAKI_BOT_TOKEN:-}" ]
}

# ============================================================================
# Install (setup-time)
# ============================================================================

bridge_install() {
  if ! command -v kimaki &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g kimaki
  else
    log "Kimaki already installed: $(kimaki --version 2>/dev/null | head -1)"
  fi

  if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    _kimaki_install_launchd
  elif [ "$LOCAL_MODE" = true ]; then
    log "Local mode: Kimaki installed. Run manually with:"
    log "  cd $SITE_PATH && kimaki"
  else
    _kimaki_install_systemd
  fi
}

_kimaki_install_launchd() {
  KIMAKI_PLIST_LABEL="com.wp.kimaki"
  KIMAKI_PLIST_DIR="$HOME/Library/LaunchAgents"
  KIMAKI_PLIST="$KIMAKI_PLIST_DIR/$KIMAKI_PLIST_LABEL.plist"

  if [ "$DRY_RUN" = true ]; then
    KIMAKI_BIN="/opt/homebrew/bin/kimaki"
  else
    KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/opt/homebrew/bin/kimaki")
  fi

  run_cmd mkdir -p "$KIMAKI_DATA_DIR"
  run_cmd mkdir -p "$KIMAKI_PLIST_DIR"

  write_file "$KIMAKI_PLIST" "$(bridge_render_launchd "$KIMAKI_PLIST_LABEL")"

  if [ "$DRY_RUN" = false ] && [ -n "$KIMAKI_BOT_TOKEN" ]; then
    launchctl bootout "gui/$(id -u)" "$KIMAKI_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$KIMAKI_PLIST"
    log "Kimaki launchd service installed and started"
  elif [ "$DRY_RUN" = false ]; then
    log "KIMAKI_BOT_TOKEN not set — service not started"
    log "Run onboarding first, then enable the service:"
    log "  cd $SITE_PATH && kimaki"
    log "  launchctl bootstrap gui/$(id -u) $KIMAKI_PLIST"
  fi

  log "Kimaki service: $KIMAKI_PLIST_LABEL"
  log "  Start:  launchctl kickstart gui/$(id -u)/$KIMAKI_PLIST_LABEL"
  log "  Stop:   launchctl kill SIGTERM gui/$(id -u)/$KIMAKI_PLIST_LABEL"
  log "  Logs:   tail -f $KIMAKI_DATA_DIR/kimaki.log"
}

_kimaki_install_systemd() {
  KIMAKI_CONFIG_DIR="/opt/kimaki-config"
  run_cmd cp -r "$SCRIPT_DIR/bridges/kimaki" "$KIMAKI_CONFIG_DIR"
  run_cmd chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"

  if [ "$DRY_RUN" = true ]; then
    KIMAKI_BIN="/usr/bin/kimaki"
  else
    KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/usr/bin/kimaki")
  fi

  local KIMAKI_BIN_DIR NODE_BIN_DIR PATH_VALUE
  KIMAKI_BIN_DIR=$(dirname "$KIMAKI_BIN")
  NODE_BIN_DIR=$(_resolve_node_bin_dir "$KIMAKI_BIN")
  PATH_VALUE=$(_compose_path_value "$KIMAKI_BIN_DIR" "$NODE_BIN_DIR" /usr/local/bin /usr/bin /bin)

  local ENV_BLOCK="Environment=HOME=$SERVICE_HOME
Environment=PATH=$PATH_VALUE
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"
  if [ -n "$KIMAKI_BOT_TOKEN" ]; then
    ENV_BLOCK="$ENV_BLOCK
Environment=KIMAKI_BOT_TOKEN=$KIMAKI_BOT_TOKEN"
  fi

  write_file "/etc/systemd/system/kimaki.service" \
    "$(bridge_render_systemd kimaki.service "$ENV_BLOCK")"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable kimaki
}

# ============================================================================
# Upgrade-time config sync (Phase 2)
# ============================================================================

bridge_sync_config() {
  # Resolve paths per environment.
  #   VPS:   plugins live at /opt/kimaki-config/plugins (referenced by opencode.json,
  #          and by ExecStartPre in kimaki.service). Config dir holds plugins +
  #          post-upgrade.sh + skills-kill-list.txt.
  #   Local: opencode.json points at $(npm root -g)/kimaki/plugins (mirrors what
  #          setup.sh / runtimes/opencode.sh writes). post-upgrade.sh + kill list
  #          have no launchd ExecStartPre hook on macOS, so we stash them at
  #          $KIMAKI_DATA_DIR/kimaki-config/ and execute post-upgrade.sh inline
  #          to enforce the kill list against the npm-installed kimaki skills.
  local KIMAKI_CONFIG_DIR
  local KIMAKI_PLUGINS_DIR
  local BACKUP_DIR
  if [ "$LOCAL_MODE" = true ]; then
    KIMAKI_CONFIG_DIR="${KIMAKI_DATA_DIR}/kimaki-config"
    local NPM_ROOT
    NPM_ROOT="$(npm root -g 2>/dev/null)"
    if [ -z "$NPM_ROOT" ]; then
      warn "  npm root -g not available — cannot resolve local plugins dir"
      return 0
    fi
    KIMAKI_PLUGINS_DIR="${NPM_ROOT}/kimaki/plugins"
    BACKUP_DIR="${KIMAKI_DATA_DIR}/backups/kimaki-config.$TIMESTAMP"
    log "Phase 2: Syncing kimaki config (local mode)..."
    log "  Config dir:  $KIMAKI_CONFIG_DIR"
    log "  Plugins dir: $KIMAKI_PLUGINS_DIR (npm-managed)"
  else
    KIMAKI_CONFIG_DIR="/opt/kimaki-config"
    KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
    BACKUP_DIR="/opt/kimaki-config.backup.$TIMESTAMP"
    log "Phase 2: Syncing /opt/kimaki-config..."
  fi

  # Local: the kimaki npm package must be installed for plugins to land
  # somewhere opencode actually loads from. Refuse to bootstrap here — the
  # user must install kimaki first.
  if [ "$LOCAL_MODE" = true ] && [ ! -d "$(dirname "$KIMAKI_PLUGINS_DIR")" ]; then
    warn "  Kimaki npm package not found at $(dirname "$KIMAKI_PLUGINS_DIR") — install with 'npm install -g kimaki'"
    return 0
  fi

  # VPS: if /opt/kimaki-config is missing, this install predates v0.4.0 (when
  # setup.sh started creating it). We're in the kimaki dispatch branch, so
  # kimaki IS the detected bridge and kimaki.service IS running — the
  # config dir just never got bootstrapped. Create it now from the repo.
  # All contents are wp-coding-agents-owned (plugins, post-upgrade.sh,
  # kill list); there is no user state to preserve.
  if [ "$LOCAL_MODE" = false ] && [ ! -d "$KIMAKI_CONFIG_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would bootstrap $KIMAKI_CONFIG_DIR from $SCRIPT_DIR/bridges/kimaki/"
    else
      log "  $KIMAKI_CONFIG_DIR missing — bootstrapping from repo (install predates v0.4.0)"
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins"
      UPDATED_ITEMS+=("bootstrapped $KIMAKI_CONFIG_DIR (install predates v0.4.0)")
      # Fall through — the plugin/post-upgrade/kill-list copy logic below
      # handles the actual file placement idempotently.
    fi
  fi

  # Backup current state (only if there's something to back up).
  if [ -d "$KIMAKI_CONFIG_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would backup $KIMAKI_CONFIG_DIR → $BACKUP_DIR"
    else
      mkdir -p "$(dirname "$BACKUP_DIR")"
      cp -r "$KIMAKI_CONFIG_DIR" "$BACKUP_DIR"
      log "  Backup created: $BACKUP_DIR"
    fi
  fi

  # Copy plugins to two targets:
  #   1. KIMAKI_CONFIG_DIR/plugins/ — the persistent source of truth that
  #      survives `npm update -g kimaki`. post-upgrade.sh restores from here
  #      on every kimaki restart.
  #   2. KIMAKI_PLUGINS_DIR (= $(npm root -g)/kimaki/plugins on local,
  #      /opt/kimaki-config/plugins on VPS) — the path opencode.json actually
  #      loads from. On VPS this is the same as #1; on local it lives inside
  #      the npm package and gets wiped on every kimaki update.
  #
  # Writing to both keeps post-upgrade.sh's restore loop working on local
  # installs without changing the VPS layout (where the two paths coincide).
  if [ -d "$SCRIPT_DIR/bridges/kimaki/plugins" ]; then
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins" 2>/dev/null || true
      mkdir -p "$KIMAKI_PLUGINS_DIR" 2>/dev/null || true
    fi
    for plugin_file in "$SCRIPT_DIR"/bridges/kimaki/plugins/*.ts; do
      [ -f "$plugin_file" ] || continue
      local name
      name=$(basename "$plugin_file")
      # Persistent source of truth (survives npm update).
      if [ "$DRY_RUN" = true ]; then
        if ! cmp -s "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name" 2>/dev/null; then
          echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/plugins/$name"
        fi
      else
        if ! cmp -s "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name" 2>/dev/null; then
          cp "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name"
          log "  Updated $KIMAKI_CONFIG_DIR/plugins/$name (persistent source)"
          UPDATED_ITEMS+=("kimaki-config/plugins/$name")
        fi
      fi
      # Live target (where opencode.json points).
      if [ "$DRY_RUN" = true ]; then
        if ! cmp -s "$plugin_file" "$KIMAKI_PLUGINS_DIR/$name" 2>/dev/null; then
          echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_PLUGINS_DIR/$name"
        else
          echo -e "${BLUE}[dry-run]${NC} $name: unchanged"
        fi
      else
        if ! cmp -s "$plugin_file" "$KIMAKI_PLUGINS_DIR/$name" 2>/dev/null; then
          cp "$plugin_file" "$KIMAKI_PLUGINS_DIR/$name"
          log "  Updated $KIMAKI_PLUGINS_DIR/$name"
          UPDATED_ITEMS+=("kimaki plugins/$name")
        fi
      fi
    done
  fi

  # Stage post-upgrade.sh and skills-kill-list.txt in KIMAKI_CONFIG_DIR.
  # On VPS this is read by ExecStartPre. On local we execute it inline below.
  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$KIMAKI_CONFIG_DIR" 2>/dev/null || true
  fi

  if [ -f "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/post-upgrade.sh"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        cp "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        log "  Updated $KIMAKI_CONFIG_DIR/post-upgrade.sh"
        UPDATED_ITEMS+=("kimaki-config/post-upgrade.sh")
      fi
    fi
  fi

  if [ -f "$SCRIPT_DIR/bridges/kimaki/skills-kill-list.txt" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/skills-kill-list.txt"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt" 2>/dev/null; then
        cp "$SCRIPT_DIR/bridges/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt"
        log "  Updated $KIMAKI_CONFIG_DIR/skills-kill-list.txt"
        UPDATED_ITEMS+=("kimaki-config/skills-kill-list.txt")
      fi
    fi
  fi

  # On local, execute post-upgrade.sh inline to enforce the kill list.
  # On VPS, kimaki.service ExecStartPre runs it on next service restart.
  if [ "$LOCAL_MODE" = true ] && [ -x "$KIMAKI_CONFIG_DIR/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would run: $KIMAKI_CONFIG_DIR/post-upgrade.sh"
    else
      log "  Running post-upgrade.sh to enforce skills kill list..."
      if "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>&1 | sed 's/^/    /'; then
        UPDATED_ITEMS+=("ran post-upgrade.sh (enforced skills kill list)")
      else
        warn "  post-upgrade.sh exited non-zero — review output above"
      fi
    fi
  fi

  # Run the effective-prompt regression test against the live kimaki install.
  #
  # This catches dm-context-filter regressions caused by kimaki upgrades that
  # reshuffle the system prompt (new sections, new code-fence patterns, new
  # banned phrases). Renders the prompt from the freshly-synced kimaki npm
  # package, runs dm-context-filter over it, asserts no banned phrases leak.
  #
  # Snapshot drift is a soft warning (the agent context is fine, the test
  # just needs `--update`). Leak failures are also surfaced as warnings,
  # not hard errors — upgrade.sh must not block on a test failure when the
  # underlying sync was successful. The signal is in UPDATED_ITEMS so the
  # final summary surfaces it.
  local TEST_SCRIPT="$SCRIPT_DIR/tests/effective-prompt/run.mjs"
  if [ -f "$TEST_SCRIPT" ] && command -v node &>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would run: node $TEST_SCRIPT"
    else
      log "  Running effective-prompt regression test..."
      local TEST_OUT
      if TEST_OUT=$(node "$TEST_SCRIPT" 2>&1); then
        # Pull the scenario count from the harness's "OK — N scenario(s)" line.
        local SCENARIO_LINE
        SCENARIO_LINE=$(echo "$TEST_OUT" | grep -E "^OK — [0-9]+ scenario" | head -1)
        log "  effective-prompt: PASS — ${SCENARIO_LINE:-no scenarios reported}"
        UPDATED_ITEMS+=("ran effective-prompt test (no filter leaks)")
      else
        warn "  effective-prompt test FAILED — dm-context-filter may be leaking banned phrases"
        warn "    rerun with: node $TEST_SCRIPT --verbose"
        warn "    if drift is intentional: node $TEST_SCRIPT --update"
        # Surface the failure section of the test output (last ~12 lines).
        echo "$TEST_OUT" | tail -12 | sed 's/^/    /' >&2
        UPDATED_ITEMS+=("effective-prompt test FAILED — review filter or refresh snapshots")
      fi
    fi
  fi

  log "  Done."

  # Export resolved paths so print_summary can reference them
  RESOLVED_KIMAKI_CONFIG_DIR="$KIMAKI_CONFIG_DIR"
  RESOLVED_KIMAKI_PLUGINS_DIR="$KIMAKI_PLUGINS_DIR"
}

# ============================================================================
# Upgrade-time service refresh (Phase 5)
# ============================================================================

bridge_update_systemd() {
  log "Phase 5: Checking kimaki.service template..."

  local UNIT_FILE="/etc/systemd/system/kimaki.service"
  [ -f "$UNIT_FILE" ] || { warn "  $UNIT_FILE does not exist — skipping"; return 0; }

  local CURRENT_ENV
  CURRENT_ENV=$(grep '^Environment=' "$UNIT_FILE" || true)

  local KIMAKI_BIN
  KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/usr/bin/kimaki")
  local KIMAKI_CONFIG_DIR="/opt/kimaki-config"
  local KIMAKI_BIN_DIR NODE_BIN_DIR PATH_VALUE
  KIMAKI_BIN_DIR=$(dirname "$KIMAKI_BIN")
  NODE_BIN_DIR=$(_resolve_node_bin_dir "$KIMAKI_BIN")
  PATH_VALUE=$(_compose_path_value "$KIMAKI_BIN_DIR" "$NODE_BIN_DIR" /usr/local/bin /usr/bin /bin)
  CURRENT_ENV=$(_ensure_systemd_path_contains "$CURRENT_ENV" "$KIMAKI_BIN_DIR")
  if [ -n "$NODE_BIN_DIR" ]; then
    CURRENT_ENV=$(_ensure_systemd_path_contains "$CURRENT_ENV" "$NODE_BIN_DIR")
  fi

  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=$PATH_VALUE
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"

  local MERGED_ENV
  MERGED_ENV=$(_merge_systemd_env_lines "$CURRENT_ENV" "$TEMPLATE_ENV")

  local NEW_UNIT
  NEW_UNIT=$(bridge_render_systemd kimaki.service "$MERGED_ENV")

  _smart_update_systemd_unit "$UNIT_FILE" "$NEW_UNIT" "kimaki.service"
}

bridge_update_launchd() {
  log "Phase 5a: Checking com.wp.kimaki launchd template..."

  local plist="$HOME/Library/LaunchAgents/com.wp.kimaki.plist"
  [ -f "$plist" ] || { warn "  $plist does not exist — skipping"; return 0; }

  local KIMAKI_BIN
  KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/opt/homebrew/bin/kimaki")

  local previous_token="${KIMAKI_BOT_TOKEN:-}"
  local token_was_set=false
  [ -n "${KIMAKI_BOT_TOKEN:-}" ] && token_was_set=true
  if [ -z "${KIMAKI_BOT_TOKEN:-}" ]; then
    KIMAKI_BOT_TOKEN=$(_plist_string_after_key "$plist" "KIMAKI_BOT_TOKEN" || true)
  fi

  local new_plist
  new_plist=$(bridge_render_launchd com.wp.kimaki)

  if [ "$token_was_set" = true ]; then
    KIMAKI_BOT_TOKEN="$previous_token"
  else
    unset KIMAKI_BOT_TOKEN
  fi

  if echo "$new_plist" | cmp -s - "$plist"; then
    log "  com.wp.kimaki.plist: unchanged"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would update $plist"
    echo -e "${BLUE}[dry-run]${NC} Diff:"
    diff -u "$plist" <(echo "$new_plist") 2>/dev/null | head -30 | sed 's/^/    /' || true
    return 0
  fi

  cp "$plist" "${plist}.backup.$TIMESTAMP"
  echo "$new_plist" > "$plist"
  log "  Updated $plist (backup: ${plist}.backup.$TIMESTAMP)"
  log "  Diff:"
  diff -u "${plist}.backup.$TIMESTAMP" "$plist" 2>/dev/null | head -30 | sed 's/^/    /' || true
  log "  NOTE: com.wp.kimaki NOT restarted — run the restart command in the summary when ready"
  UPDATED_ITEMS+=("com.wp.kimaki.plist (not restarted)")
}

# ============================================================================
# Templates: systemd unit + launchd plist
# ============================================================================

bridge_render_systemd() {
  local unit="$1" env_block="$2"
  [ "$unit" = "kimaki.service" ] || { echo "kimaki has no unit '$unit'" >&2; return 1; }
  cat <<EOF
[Unit]
Description=Kimaki Discord Bot (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
ExecStartPre=$KIMAKI_CONFIG_DIR/post-upgrade.sh
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

bridge_render_launchd() {
  local label="$1"
  [ "$label" = "com.wp.kimaki" ] || { echo "kimaki has no label '$label'" >&2; return 1; }
  local kimaki_bin_dir node_bin_dir path_value
  kimaki_bin_dir="$(dirname "$KIMAKI_BIN")"
  node_bin_dir="$(_resolve_node_bin_dir "$KIMAKI_BIN")"
  path_value="$(_compose_path_value "$kimaki_bin_dir" "$node_bin_dir" /opt/homebrew/bin /usr/local/bin /usr/bin /bin)"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$KIMAKI_BIN</string>
        <string>--data-dir</string>
        <string>$KIMAKI_DATA_DIR</string>
        <string>--auto-restart</string>
        <string>--no-critique</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$KIMAKI_DATA_DIR/kimaki.log</string>
    <key>StandardErrorPath</key>
    <string>$KIMAKI_DATA_DIR/kimaki.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$path_value</string>
        <key>KIMAKI_DATA_DIR</key>
        <string>$KIMAKI_DATA_DIR</string>$(if [ -n "${KIMAKI_BOT_TOKEN:-}" ]; then echo "
        <key>KIMAKI_BOT_TOKEN</key>
        <string>$KIMAKI_BOT_TOKEN</string>"; fi)
    </dict>
</dict>
</plist>
EOF
}

# ============================================================================
# Human-facing command accessors
# ============================================================================

bridge_restart_cmd() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd)
      echo "launchctl bootout gui/${uid} ~/Library/LaunchAgents/com.wp.kimaki.plist 2>/dev/null || true; launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/com.wp.kimaki.plist"
      ;;
    local-manual)
      echo "cd $SITE_PATH && kimaki"
      ;;
    vps)
      echo "systemctl restart kimaki"
      ;;
    *)
      echo "bridge_restart_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_verify_cmd() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd) echo "launchctl print gui/${uid}/com.wp.kimaki | head -20" ;;
    local-manual)  echo "pgrep -fl kimaki" ;;
    vps)           echo "systemctl status kimaki" ;;
    *)
      echo "bridge_verify_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_logs_cmd() {
  echo "tail -f $KIMAKI_DATA_DIR/kimaki.log"
}

bridge_start_hint() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd) echo "launchctl kickstart gui/${uid}/com.wp.kimaki" ;;
    local-manual)  bridge_restart_cmd local-manual ;;
    vps)           echo "systemctl start kimaki" ;;
    *)
      echo "bridge_start_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_stop_hint() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd) echo "launchctl kill SIGTERM gui/${uid}/com.wp.kimaki" ;;
    vps)           echo "systemctl stop kimaki" ;;
    local-manual)  ;;
    *)
      echo "bridge_stop_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

# ============================================================================
# Summary blocks (lib/summary.sh next-steps prose)
# ============================================================================

# Onboarding prose for VPS when KIMAKI_BOT_TOKEN is missing.
bridge_vps_setup_block() {
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
}

# Onboarding prose for macOS launchd when KIMAKI_BOT_TOKEN is missing.
bridge_launchd_setup_block() {
  local uid
  uid=$(id -u)
  echo "  Kimaki setup:"
  echo "    1. Run onboarding:  cd $SITE_PATH && kimaki"
  echo "    2. Enable service:  launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/com.wp.kimaki.plist"
}

# Optional preamble for VPS start-block when creds ARE configured.
bridge_vps_start_preamble() {
  echo "  Bot token configured via KIMAKI_BOT_TOKEN."
}

# Verify-block addendum printed by upgrade.sh after the standard status line.
bridge_verify_extra() {
  local PLUGINS_DIR="${RESOLVED_KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"
  echo "ls $PLUGINS_DIR   # plugin versions"
}
