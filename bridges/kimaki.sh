#!/bin/bash
# bridges/kimaki.sh — Kimaki Discord bridge.
#
# Owns install (local launchd / VPS systemd / Linux-local manual), upgrade-time
# config sync (plugins, post-upgrade.sh, skill filters, regression test),
# systemd + launchd template rendering, summary blocks, and the per-bridge
# assets at bridges/kimaki/ (plugins/, post-upgrade.sh, skills-disable-list.txt).
#
# Install layout:
#   VPS:   /opt/kimaki-config/{plugins,post-upgrade.sh,skills-disable-list.txt}
#          + /usr/local/bin/datamachine-kimaki-session
#          + /usr/local/bin/datamachine-kimaki
#          + /etc/systemd/system/kimaki.service (ExecStartPre runs post-upgrade.sh)
#   Local: $KIMAKI_DATA_DIR/kimaki-config/ for plugins, post-upgrade.sh +
#          skill filters (executed inline at upgrade time — no launchd
#          ExecStartPre hook). opencode.json loads plugins directly from this
#          durable data-dir copy because `npm update -g kimaki` wipes package-
#          local files.
#          + $HOME/.local/bin/datamachine-kimaki-session
#          + $HOME/.local/bin/datamachine-kimaki
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

  _kimaki_sync_bin_helpers
  _kimaki_register_cli_channel
  _kimaki_register_runtime_signature
}

# _kimaki_register_cli_channel
#
# Register kimaki with the Data Machine Code CLI transport runtime so that
# `agents/dispatch-message` (substrate: Automattic/agents-api) can deliver
# messages to Discord channels by shelling kimaki. `recipient` is the Discord
# channel ID (numeric string) the message is delivered to. `message` is the
# message body.
#
# We register the local-mode adapter shim (`datamachine-kimaki`) installed by
# _kimaki_sync_bin_helpers; it normalises Kimaki send flags across versions.
# Falls back to the resolved global `kimaki` binary if the adapter isn't on
# disk yet (early VPS installs predating the adapter shim).
_kimaki_register_cli_channel() {
  local cmd
  if [ -n "${RESOLVED_DATAMACHINE_KIMAKI:-}" ] && [ -x "$RESOLVED_DATAMACHINE_KIMAKI" ]; then
    cmd="$RESOLVED_DATAMACHINE_KIMAKI"
  elif [ -n "${KIMAKI_BIN:-}" ]; then
    cmd="$KIMAKI_BIN"
  else
    cmd="$(command -v kimaki 2>/dev/null || echo kimaki)"
  fi

  cli_channel_register \
    "kimaki" \
    "$cmd" \
    '["send","--channel","{recipient}","--prompt","{message}"]' \
    "true" \
    "600"
}

# _kimaki_register_runtime_signature
#
# Publish kimaki's worktree session-attribution env-var contract for the Data
# Machine Code worktree-attribution code (Extra-Chill/data-machine-code#416).
# kimaki sets KIMAKI_SESSION_ID, KIMAKI_THREAD_ID, and KIMAKI_THREAD_URL on
# the opencode-serve children it spawns (see Kimaki source). DMC reads those
# env vars at worktree-create time to record which kimaki session originated
# the worktree, what Discord thread the session lives in, and the deep link
# to that thread.
#
# The registration is data, not config: the runtime ID 'kimaki' is what
# wp-coding-agents *calls* the runtime here, and the env-var names are what
# the kimaki binary actually sets. DMC stays naive — it doesn't know kimaki
# exists; it just sniffs whatever env vars the filter map tells it to.
_kimaki_register_runtime_signature() {
  runtime_signature_register \
    "kimaki" \
    '{"session_id":"KIMAKI_SESSION_ID","thread_id":"KIMAKI_THREAD_ID","thread_url":"KIMAKI_THREAD_URL"}'
}

_kimaki_sync_bin_helpers() {
  [ -d "$SCRIPT_DIR/bridges/kimaki/bin" ] || return 0

  local HELPER_DIR
  if [ "$LOCAL_MODE" = true ]; then
    HELPER_DIR="$SERVICE_HOME/.local/bin"
  else
    HELPER_DIR="/usr/local/bin"
  fi

  local helper_file name helper_target
  for helper_file in "$SCRIPT_DIR"/bridges/kimaki/bin/*; do
    [ -f "$helper_file" ] || continue
    name=$(basename "$helper_file")
    helper_target="$HELPER_DIR/$name"

    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$helper_file" "$helper_target" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $helper_target"
      fi
    else
      mkdir -p "$HELPER_DIR"
      if ! cmp -s "$helper_file" "$helper_target" 2>/dev/null; then
        cp "$helper_file" "$helper_target"
        chmod +x "$helper_target"
        log "  Updated $helper_target"
        UPDATED_ITEMS+=("$name helper")
      fi
    fi
  done

  _kimaki_sync_command_shim "$HELPER_DIR"

  RESOLVED_KIMAKI_HELPER="$HELPER_DIR/datamachine-kimaki-session"
  RESOLVED_DATAMACHINE_KIMAKI="$HELPER_DIR/datamachine-kimaki"
  RESOLVED_KIMAKI_SHIM="$HELPER_DIR/kimaki"
}

_kimaki_sync_command_shim() {
  local helper_dir="$1"
  local adapter_source="$SCRIPT_DIR/bridges/kimaki/bin/datamachine-kimaki"
  local shim_target="$helper_dir/kimaki"
  [ -f "$adapter_source" ] || return 0

  if [ -e "$shim_target" ] && ! grep -q 'wp-coding-agents datamachine-kimaki adapter' "$shim_target" 2>/dev/null; then
    warn "  $shim_target exists and is not the Data Machine Kimaki adapter — leaving it untouched"
    warn "  Install $helper_dir earlier on PATH or call datamachine-kimaki directly to normalize Kimaki send flags"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    if ! cmp -s "$adapter_source" "$shim_target" 2>/dev/null; then
      echo -e "${BLUE}[dry-run]${NC} Would update $shim_target"
    fi
    return 0
  fi

  mkdir -p "$helper_dir"
  if ! cmp -s "$adapter_source" "$shim_target" 2>/dev/null; then
    cp "$adapter_source" "$shim_target"
    chmod +x "$shim_target"
    log "  Updated $shim_target"
    UPDATED_ITEMS+=("kimaki command shim")
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
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR
Environment=DATAMACHINE_SITE_PATH=$SITE_PATH"
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
  #          post-upgrade.sh + skills-disable-list.txt.
  #   Local: opencode.json points at $KIMAKI_DATA_DIR/kimaki-config/plugins, the
  #          durable source that survives `npm update -g kimaki`. Existing configs
  #          that still reference package-local plugin paths are migrated by the
  #          opencode.json repair helper.
  local KIMAKI_CONFIG_DIR
  local KIMAKI_PLUGINS_DIR
  local BACKUP_DIR
  if [ "$LOCAL_MODE" = true ]; then
    KIMAKI_CONFIG_DIR="${KIMAKI_DATA_DIR}/kimaki-config"
    KIMAKI_PLUGINS_DIR="${KIMAKI_CONFIG_DIR}/plugins"
    BACKUP_DIR="${KIMAKI_DATA_DIR}/backups/kimaki-config.$TIMESTAMP"
    log "Phase 2: Syncing kimaki config (local mode)..."
    log "  Config dir:  $KIMAKI_CONFIG_DIR"
    log "  Plugins dir: $KIMAKI_PLUGINS_DIR (durable opencode target)"
  else
    KIMAKI_CONFIG_DIR="/opt/kimaki-config"
    KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
    BACKUP_DIR="/opt/kimaki-config.backup.$TIMESTAMP"
    log "Phase 2: Syncing /opt/kimaki-config..."
  fi

  # Local opencode loads from the durable kimaki-config dir. Do not mirror these
  # plugins into the npm package; `npm update -g kimaki` wipes that directory and
  # the repair helper migrates older opencode.json files away from it.

  # VPS: if /opt/kimaki-config is missing, this install predates v0.4.0 (when
  # setup.sh started creating it). We're in the kimaki dispatch branch, so
  # kimaki IS the detected bridge and kimaki.service IS running — the
  # config dir just never got bootstrapped. Create it now from the repo.
  # All contents are wp-coding-agents-owned (plugins, post-upgrade.sh,
  # skill filters); there is no user state to preserve.
  if [ "$LOCAL_MODE" = false ] && [ ! -d "$KIMAKI_CONFIG_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would bootstrap $KIMAKI_CONFIG_DIR from $SCRIPT_DIR/bridges/kimaki/"
    else
      log "  $KIMAKI_CONFIG_DIR missing — bootstrapping from repo (install predates v0.4.0)"
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins"
      UPDATED_ITEMS+=("bootstrapped $KIMAKI_CONFIG_DIR (install predates v0.4.0)")
      # Fall through — the plugin/post-upgrade/skill-filter copy logic below
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

  # Copy plugins to the durable target that opencode.json loads.
  if [ -d "$SCRIPT_DIR/bridges/kimaki/plugins" ]; then
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins" 2>/dev/null || true
      mkdir -p "$KIMAKI_PLUGINS_DIR" 2>/dev/null || true
    fi
    for plugin_file in "$SCRIPT_DIR"/bridges/kimaki/plugins/*.ts; do
      [ -f "$plugin_file" ] || continue
      local name
      name=$(basename "$plugin_file")
      # Durable source of truth (and opencode.json target).
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
    done
  fi

  # Stage post-upgrade.sh and skills-disable-list.txt in KIMAKI_CONFIG_DIR.
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

  if [ -f "$SCRIPT_DIR/bridges/kimaki/skills-disable-list.txt" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/skills-disable-list.txt" "$KIMAKI_CONFIG_DIR/skills-disable-list.txt" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/skills-disable-list.txt"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/skills-disable-list.txt" "$KIMAKI_CONFIG_DIR/skills-disable-list.txt" 2>/dev/null; then
        cp "$SCRIPT_DIR/bridges/kimaki/skills-disable-list.txt" "$KIMAKI_CONFIG_DIR/skills-disable-list.txt"
        log "  Updated $KIMAKI_CONFIG_DIR/skills-disable-list.txt"
        UPDATED_ITEMS+=("kimaki-config/skills-disable-list.txt")
      fi
    fi
  fi

  # Install wp-coding-agents' Kimaki bridge helpers. They are intentionally
  # outside Kimaki's npm package so `npm update -g kimaki` cannot wipe them.
  _kimaki_sync_bin_helpers

  # On local, execute post-upgrade.sh inline to restore wp-coding-agents skills.
  # On VPS, kimaki.service ExecStartPre runs it on next service restart.
  if [ "$LOCAL_MODE" = true ] && [ -x "$KIMAKI_CONFIG_DIR/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would run: $KIMAKI_CONFIG_DIR/post-upgrade.sh"
    else
      log "  Running post-upgrade.sh to restore wp-coding-agents skills..."
      if "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>&1 | sed 's/^/    /'; then
        UPDATED_ITEMS+=("ran post-upgrade.sh (restored wp-coding-agents skills)")
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

  # Refresh the CLI-channel registration so DMC's dispatch runtime picks up
  # the latest adapter path (npm-global moves between hosts).
  _kimaki_register_cli_channel

  # Refresh the worktree runtime-signature registration. Idempotent — only
  # touches disk when the env-var map drifts (e.g. a new subkey is added in
  # a future kimaki release).
  _kimaki_register_runtime_signature

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
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR
Environment=DATAMACHINE_SITE_PATH=$SITE_PATH"

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
  local skill_filter_args
  skill_filter_args="$(_kimaki_skill_filter_args_shell)"
  cat <<EOF
[Unit]
Description=Kimaki Discord Bot (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
# Reap stray opencode-serve children left behind by the previous kimaki
# process before starting a fresh one. Each kimaki session spawns its own
# opencode-serve worker; if kimaki exits uncleanly (crash, OOM, manual
# kill) those workers are reparented to PID 1 and keep running. They all
# share \$HOME/.local/share/opencode/auth.json, so concurrent OAuth
# refreshes race each other — Anthropic rotates the refresh token on every
# use, and the loser of the race gets HTTP 400 invalid_grant on its next
# request. \`pkill -u $SERVICE_USER\` scopes the kill to this service's
# user so multi-tenant hosts aren't sniped. The \`-\` prefix makes systemd
# tolerate exit code 1 (no matches found, the happy path on a clean box).
ExecStartPre=-/usr/bin/pkill -TERM -u $SERVICE_USER -f "opencode-ai/bin/.*serve"
ExecStartPre=$KIMAKI_CONFIG_DIR/post-upgrade.sh
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique$skill_filter_args
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
  path_value="$(_compose_path_value "$HOME/.local/bin" "$kimaki_bin_dir" "$node_bin_dir" "$HOME/.opencode/bin" "$HOME/.bun/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)"
  local skill_filter_plist_args
  skill_filter_plist_args="$(_kimaki_skill_filter_args_plist)"
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
$skill_filter_plist_args
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
        <string>$KIMAKI_DATA_DIR</string>
        <key>DATAMACHINE_SITE_PATH</key>
        <string>$SITE_PATH</string>$(if [ -n "${KIMAKI_BOT_TOKEN:-}" ]; then echo "
        <key>KIMAKI_BOT_TOKEN</key>
        <string>$KIMAKI_BOT_TOKEN</string>"; fi)
    </dict>
</dict>
</plist>
EOF
}

_kimaki_skill_filter_source() {
  if [ -n "${KIMAKI_SKILL_FILTERS_FILE:-}" ]; then
    printf '%s\n' "$KIMAKI_SKILL_FILTERS_FILE"
  elif [ -n "${KIMAKI_CONFIG_DIR:-}" ] && [ -f "$KIMAKI_CONFIG_DIR/skills-disable-list.txt" ]; then
    printf '%s\n' "$KIMAKI_CONFIG_DIR/skills-disable-list.txt"
  elif [ -n "${KIMAKI_DATA_DIR:-}" ] && [ -f "$KIMAKI_DATA_DIR/kimaki-config/skills-disable-list.txt" ]; then
    printf '%s\n' "$KIMAKI_DATA_DIR/kimaki-config/skills-disable-list.txt"
  else
    printf '%s\n' "$SCRIPT_DIR/bridges/kimaki/skills-disable-list.txt"
  fi
}

_kimaki_each_disabled_skill() {
  local filters_file skill
  filters_file="$(_kimaki_skill_filter_source)"
  [ -f "$filters_file" ] || return 0

  while IFS= read -r skill || [ -n "$skill" ]; do
    [ -n "$skill" ] || continue
    case "$skill" in \#*) continue ;; esac
    printf '%s\n' "$skill"
  done < "$filters_file"
}

_kimaki_skill_filter_args_shell() {
  local out="" skill
  while IFS= read -r skill; do
    out="$out --disable-skill $skill"
  done < <(_kimaki_each_disabled_skill)
  printf '%s' "$out"
}

_kimaki_skill_filter_args_plist() {
  local out="" skill
  while IFS= read -r skill; do
    out="$out        <string>--disable-skill</string>
        <string>$skill</string>
"
  done < <(_kimaki_each_disabled_skill)
  printf '%s' "$out"
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
  local HELPER="${RESOLVED_KIMAKI_HELPER:-/usr/local/bin/datamachine-kimaki-session}"
  local ADAPTER="${RESOLVED_DATAMACHINE_KIMAKI:-/usr/local/bin/datamachine-kimaki}"
  local SHIM="${RESOLVED_KIMAKI_SHIM:-/usr/local/bin/kimaki}"
  echo "test -f $PLUGINS_DIR/dm-context-filter.ts && test -f $PLUGINS_DIR/dm-agent-sync.ts   # DM OpenCode plugins installed"
  echo "test -x $HELPER   # DMC Kimaki session handoff helper installed"
  echo "test -x $ADAPTER   # DM Kimaki command adapter installed"
  echo "test -x $SHIM   # kimaki command shim installed"
}
