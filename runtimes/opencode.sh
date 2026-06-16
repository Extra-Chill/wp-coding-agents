#!/bin/bash
# Runtime: OpenCode — install, config generation, AGENTS.md, MCP merge

runtime_install() {
  log "Phase 7: Installing OpenCode..."

  if ! command -v opencode &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g opencode-ai
  else
    log "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'unknown')"
  fi

  _remove_legacy_opencode_wrapper
  _opencode_register_runtime_signature
}

# _opencode_register_runtime_signature
#
# Publish opencode's worktree session-attribution env-var contract for the
# Data Machine Code worktree-attribution code (Extra-Chill/data-machine-code#416).
# OpenCode sets OPENCODE_RUN_ID on worker/tool processes. Source review and a
# live Kimaki/OpenCode 0.13 smoke did not find OPENCODE_SESSION_ID, so only the
# real exported run identifier is registered here.
#
# Registered from runtime_install (setup-time) and from the legacy-wrapper-
# removal phase in upgrade.sh, which is the upgrade-time entry point that
# already sources runtimes/opencode.sh. Re-running is harmless: the writer
# is idempotent and only mutates the mu-plugin file when the env-var map
# actually differs.
_opencode_register_runtime_signature() {
  if ! declare -F runtime_signature_register >/dev/null; then
    # The helper lives in lib/runtime-signature.sh, sourced by setup.sh and
    # upgrade.sh. When this function is invoked outside those entry points
    # (e.g. by a test that sources just runtimes/opencode.sh in isolation),
    # silently skip — registration is not the runtime's primary job.
    return 0
  fi
  runtime_signature_register \
    "opencode" \
    '{"run_id":"OPENCODE_RUN_ID"}'
}

# Remove any legacy wp-coding-agents-opencode-wrapper-v2 bash shim that prior
# upgrades installed at the global `opencode` path. The wrapper existed to
# feed Anthropic OAuth credentials into ~/.claude/.credentials.json for the
# opencode-claude-auth plugin. wp-coding-agents no longer ships, installs, or
# patches that plugin: Kimaki's built-in AnthropicAuthPlugin handles OAuth
# (token refresh, multi-account rotation, request rewriting), and non-kimaki
# bridges authenticate via opencode's native auth flow. The wrapper is purely
# legacy and must not be re-installed by any future upgrade run.
_remove_legacy_opencode_wrapper() {
  local OPENCODE_BIN
  OPENCODE_BIN=$(command -v opencode 2>/dev/null || echo "")
  [ -n "$OPENCODE_BIN" ] || return 0
  [ -f "$OPENCODE_BIN" ] || return 0

  # Only act on the known wp-coding-agents wrapper sentinel — never touch a
  # binary or a wrapper installed by anything else.
  if ! grep -q "wp-coding-agents-opencode-wrapper" "$OPENCODE_BIN" 2>/dev/null; then
    return 0
  fi

  # Recover the real binary path from the wrapper's `exec` line so we can
  # restore the global `opencode` symlink/hardlink to it.
  local REAL_BIN=""
  while IFS= read -r line; do
    case "$line" in
      exec\ *opencode*|exec\ /*opencode*)
        set -- $line
        REAL_BIN="${2#\'}"
        REAL_BIN="${REAL_BIN%\'}"
        REAL_BIN="${REAL_BIN#\"}"
        REAL_BIN="${REAL_BIN%\"}"
        ;;
    esac
  done < "$OPENCODE_BIN"

  # Fall back to the npm-shipped layout: opencode-ai keeps the real binary at
  # bin/.opencode and ships a wrapper at bin/opencode in older versions; newer
  # versions hardlink them. Either way, .opencode is the canonical real binary.
  if [ -z "$REAL_BIN" ] || [ ! -f "$REAL_BIN" ]; then
    REAL_BIN="/usr/lib/node_modules/opencode-ai/bin/.opencode"
  fi

  if [ ! -f "$REAL_BIN" ]; then
    warn "Legacy opencode wrapper detected at $OPENCODE_BIN but real binary not found — leaving alone"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would remove legacy opencode wrapper at $OPENCODE_BIN and link to $REAL_BIN"
    return 0
  fi

  log "Removing legacy opencode wrapper at $OPENCODE_BIN (real binary: $REAL_BIN)"
  rm -f "$OPENCODE_BIN" "${OPENCODE_BIN}.bak."* 2>/dev/null || true
  if ! ln "$REAL_BIN" "$OPENCODE_BIN" 2>/dev/null; then
    ln -s "$REAL_BIN" "$OPENCODE_BIN"
  fi
  UPDATED_ITEMS+=("removed legacy opencode wrapper")
}

runtime_discover_dm_paths() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_FLAG=""
    if [ -n "$AGENT_SLUG" ]; then
      AGENT_FLAG="--agent=$AGENT_SLUG"
    fi
    DM_INJECTABLE_RAW=$(wp_cmd datamachine memory injectable-files --format=json $AGENT_FLAG 2>/dev/null || echo "")
    # SQLite translation layer may emit HTML error noise — extract only JSON.
    DM_INJECTABLE_JSON=$(echo "$DM_INJECTABLE_RAW" | sed -n '/^\[/,/^\]/p')
    if [ -n "$DM_INJECTABLE_JSON" ]; then
      DM_AGENT_FILES=$(echo "$DM_INJECTABLE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data:
    path = f.get('path')
    if path:
        print(path)
")
      log "Agent files discovered via '$WP_CMD datamachine memory injectable-files${AGENT_FLAG:+ ($AGENT_FLAG)}'"
      return
    fi

    DM_PATHS_RAW=$(wp_cmd datamachine memory paths --format=json $AGENT_FLAG 2>/dev/null || echo "")
    DM_PATHS_JSON=$(echo "$DM_PATHS_RAW" | sed -n '/^{/,/^}/p')
    if [ -z "$DM_PATHS_JSON" ]; then
      error "'$WP_CMD datamachine memory injectable-files' and '$WP_CMD datamachine memory paths' returned no JSON — is Data Machine active and agent created?"
    fi
    DM_AGENT_FILES=$(echo "$DM_PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
")
    log "Agent files discovered via '$WP_CMD datamachine memory paths${AGENT_FLAG:+ ($AGENT_FLAG)}'"
  else
    # Dry-run: use placeholder paths
    DM_DRY_SLUG="${AGENT_SLUG:-AGENT_SLUG}"
    DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/SOUL.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/MEMORY.md
wp-content/uploads/datamachine-files/users/USER_ID/USER.md"
    log "Dry-run: using placeholder agent paths (slug: $DM_DRY_SLUG)"
  fi
}

runtime_generate_config() {
  # Resolve Kimaki plugin dir + copy plugin files FIRST, unconditionally.
  # Setup.sh must be idempotent: whether this site has a fresh install or an
  # existing opencode.json, the kimaki plugins dir on disk must end up with
  # the current dm-context-filter.ts + dm-agent-sync.ts. dm-agent-sync only
  # recomposes Data Machine memory; it must not write config.agent.* prompts.
  # Previously this only ran on fresh installs because the whole function
  # early-returned on an existing file, which left upgraded installs missing
  # the security policy filter they're meant to run with. See
  # wp-coding-agents#67.
  KIMAKI_PLUGINS_DIR=""
  if [ "$CHAT_BRIDGE" = "kimaki" ]; then
    if [ "$LOCAL_MODE" = true ]; then
      KIMAKI_PLUGINS_DIR="${KIMAKI_DATA_DIR:-$HOME/.kimaki}/kimaki-config/plugins"
      if [ "$DRY_RUN" = false ] && [ -n "$KIMAKI_PLUGINS_DIR" ] && [ -d "$(dirname "$KIMAKI_PLUGINS_DIR")" ]; then
        mkdir -p "$KIMAKI_PLUGINS_DIR"
        cp "$SCRIPT_DIR/bridges/kimaki/plugins/dm-context-filter.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
        cp "$SCRIPT_DIR/bridges/kimaki/plugins/dm-agent-sync.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
      fi
    else
      KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
    fi
  fi

  # On existing opencode.json, delegate to the repair helper in --additive
  # mode. This adds managed plugin entries the user is missing and applies
  # the prompt → instructions migration (fixes Anthropic Claude Max OAuth,
  # wp-coding-agents#60) without touching user-added plugins, model settings,
  # MCP config, permissions, or other keys. Idempotent on clean installs.
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/opencode.json" ]; then
    _runtime_repair_opencode_json_additive
    return
  fi

  log "Generating opencode.json..."

  OPENCODE_JSON="{"
  OPENCODE_JSON="$OPENCODE_JSON\n  \"\$schema\": \"https://opencode.ai/config.json\""

  if [ -n "$OPENCODE_MODEL" ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"model\": \"${OPENCODE_MODEL}\""
  fi
  if [ -n "$OPENCODE_SMALL_MODEL" ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"small_model\": \"${OPENCODE_SMALL_MODEL}\""
  fi

  # OpenCode plugins. wp-coding-agents only manages plugins it owns end to
  # end: dm-context-filter.ts and dm-agent-sync.ts on Kimaki bridges. The sync
  # plugin refreshes composed memory files without mutating config.agent slots.
  # opencode-claude-auth plugin is intentionally NOT installed on any bridge:
  # Kimaki ships a built-in AnthropicAuthPlugin and non-kimaki bridges use
  # opencode's native auth flow (`opencode auth login anthropic`). See
  # Extra-Chill/wp-coding-agents#117.
  OPENCODE_PLUGINS=""
  if [ "$CHAT_BRIDGE" = "kimaki" ]; then
    OPENCODE_PLUGINS="${OPENCODE_PLUGINS}\n    \"${KIMAKI_PLUGINS_DIR}/dm-context-filter.ts\","
    OPENCODE_PLUGINS="${OPENCODE_PLUGINS}\n    \"${KIMAKI_PLUGINS_DIR}/dm-agent-sync.ts\","
  fi

  if [ -n "$OPENCODE_PLUGINS" ]; then
    # Remove trailing comma from last plugin entry
    OPENCODE_PLUGINS=$(echo "$OPENCODE_PLUGINS" | sed 's/,$//')
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"plugin\": [${OPENCODE_PLUGINS}\n  ]"
  fi

  # Memory files as top-level "instructions" array.
  #
  # Why not "agent.build.prompt"/"agent.plan.prompt": setting those overrides
  # OpenCode's canonical system prompt opening (<environment>...Skills provide...),
  # which puts our memory at the top of system[1]. Anthropic's third-party-app
  # detector fingerprints the first bytes of system[1] for Claude Max OAuth;
  # when the canonical opening isn't there, it routes the request through
  # extra-usage billing and returns HTTP 400:
  #   "Third-party apps now draw from your extra usage..."
  #
  # "instructions" loads each file via OpenCode's native Instruction.system()
  # (packages/opencode/src/session/instruction.ts), which appends them with
  # the "Instructions from: <path>" prefix AFTER the canonical opening — same
  # mechanism that auto-discovers AGENTS.md. Keeps the OAuth flow intact.
  if [ -n "$DM_AGENT_FILES" ]; then
    OPENCODE_INSTRUCTIONS=""
    while IFS= read -r rel_path; do
      [ -z "$rel_path" ] && continue
      case "$rel_path" in
        /*|http://*|https://*|~/*)
          OPENCODE_INSTRUCTIONS="${OPENCODE_INSTRUCTIONS}\n    \"${rel_path}\","
          ;;
        *)
          OPENCODE_INSTRUCTIONS="${OPENCODE_INSTRUCTIONS}\n    \"./${rel_path}\","
          ;;
      esac
    done <<< "$DM_AGENT_FILES"
    if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
      OPENCODE_INSTRUCTIONS=$(echo "$OPENCODE_INSTRUCTIONS" | sed 's/,$//')
      OPENCODE_JSON="$OPENCODE_JSON,\n  \"instructions\": [${OPENCODE_INSTRUCTIONS}\n  ]"
    fi
  fi

  # Permission: allow DM workspace as external directory
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"permission\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"external_directory\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"${DM_WORKSPACE_DIR}/**\": \"allow\""
  OPENCODE_JSON="$OPENCODE_JSON\n    }"
  OPENCODE_JSON="$OPENCODE_JSON\n  }"

  OPENCODE_JSON="$OPENCODE_JSON\n}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write to $SITE_PATH/opencode.json"
  else
    echo -e "$OPENCODE_JSON" > "$SITE_PATH/opencode.json"
  fi
}

# Additive repair of an existing opencode.json. Called when runtime_generate_config
# finds the file already on disk. Adds managed plugin entries the user is missing,
# migrates legacy agent.*.prompt → instructions (see wp-coding-agents#60), never
# removes user-added plugins. For the opt-in full reconciliation that also removes
# unexpected entries, users run `./upgrade.sh --repair-opencode-json`.
_runtime_repair_opencode_json_additive() {
  local HELPER="$SCRIPT_DIR/lib/repair-opencode-json.py"
  if [ ! -f "$HELPER" ]; then
    log "opencode.json exists but repair helper not found ($HELPER) — leaving as-is"
    return
  fi

  local BRIDGE_ARG="${CHAT_BRIDGE:-none}"
  local PLUGINS_DIR="${KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"
  local SUFFIX
  SUFFIX="$(date +%Y%m%d-%H%M%S)"
  local MANAGED_INSTRUCTIONS_FILE=""
  local managed_args=()
  if [ -n "${DM_AGENT_FILES:-}" ]; then
    MANAGED_INSTRUCTIONS_FILE=$(mktemp)
    printf '%s\n' "$DM_AGENT_FILES" > "$MANAGED_INSTRUCTIONS_FILE"
    managed_args=(--managed-instructions-file "$MANAGED_INSTRUCTIONS_FILE")
  fi

  log "opencode.json already exists — running additive repair..."

  local repair_out repair_rc
  repair_out=$(python3 "$HELPER" \
    --file "$SITE_PATH/opencode.json" \
    --runtime opencode \
    --chat-bridge "$BRIDGE_ARG" \
    --kimaki-plugins-dir "$PLUGINS_DIR" \
    "${managed_args[@]}" \
    --additive \
    --backup-suffix "$SUFFIX" 2>&1) && repair_rc=0 || repair_rc=$?
  [ -z "$MANAGED_INSTRUCTIONS_FILE" ] || rm -f "$MANAGED_INSTRUCTIONS_FILE"

  local repair_status
  repair_status=$(echo "$repair_out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','?'))" 2>/dev/null || echo "parse-error")

  case "$repair_status" in
    ok)
      log "  opencode.json already up to date"
      ;;
    additive_repaired)
      log "  opencode.json repaired additively (backup: $SITE_PATH/opencode.json.backup.$SUFFIX)"
      log "  $repair_out"
      ;;
    needs_full_repair)
      warn "  opencode.json additively repaired, but unexpected plugin entries remain"
      warn "  Review and run './upgrade.sh --repair-opencode-json' if you want them removed"
      warn "  $repair_out"
      ;;
    *)
      warn "  repair-opencode-json.py returned status=$repair_status (rc=$repair_rc)"
      warn "  $repair_out"
      ;;
  esac
}

runtime_generate_instructions() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
    log "Phase 8: AGENTS.md already exists — skipping (delete to regenerate)"
    _opencode_symlink_claude_md
    return
  fi

  log "Phase 8: Generating AGENTS.md..."

  # Compose from Data Machine's SectionRegistry. DM is mandatory, and compose
  # handles WP-CLI prefix resolution, multisite detection, and plugin sections
  # (intelligence, etc.) automatically at runtime.
  if [ "$DRY_RUN" = false ]; then
    sync_homeboy_availability
    if wp_cmd datamachine memory compose AGENTS.md 2>/dev/null; then
      log "AGENTS.md composed from SectionRegistry"
      _opencode_symlink_claude_md
      return
    fi
    warn "Compose failed — falling back to static template"
  fi

  # Fallback for dry-run or compose failure: ship a minimal static template.
  local agents_tmpl="$SCRIPT_DIR/workspace/AGENTS.md"
  if [ ! -f "$agents_tmpl" ]; then
    error "AGENTS.md template not found at $agents_tmpl"
  fi

  local wp_cli_display="wp"
  if [ "$IS_STUDIO" = true ]; then
    wp_cli_display="studio wp"
  elif [ "$LOCAL_MODE" = false ]; then
    wp_cli_display="wp $WP_ROOT_FLAG --path=$SITE_PATH"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would generate AGENTS.md from template"
    echo -e "${BLUE}[dry-run]${NC} Would symlink CLAUDE.md → AGENTS.md (Claude-model context)"
  else
    sed "s|{{WP_CLI_CMD}}|$wp_cli_display|g" "$agents_tmpl" > "$SITE_PATH/AGENTS.md"
    _opencode_symlink_claude_md
  fi
}

# Symlink CLAUDE.md → AGENTS.md so Claude-model opencode sessions inherit the
# same DM context. OpenCode globs ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"] from
# cwd; Claude Code reads only CLAUDE.md. Relative target survives directory moves.
# Skipped when CLAUDE.md is a regular file (claude-code runtime
# manage their own template-based CLAUDE.md).
# See: Extra-Chill/wp-coding-agents#108
_opencode_symlink_claude_md() {
  local agents_md="$SITE_PATH/AGENTS.md"
  local claude_md="$SITE_PATH/CLAUDE.md"
  [ -f "$agents_md" ] || return 0
  if [ -L "$claude_md" ] || [ ! -e "$claude_md" ]; then
    (cd "$SITE_PATH" && ln -sf AGENTS.md CLAUDE.md)
    log "Symlinked CLAUDE.md → AGENTS.md (covers Claude-model opencode sessions)"
  fi
}

runtime_merge_mcp_servers() {
  if [ -z "${MCP_SERVERS:-}" ] || [ ! -f "$SITE_PATH/opencode.json" ]; then
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge MCP_SERVERS into opencode.json"
    return
  fi

  command -v jq &>/dev/null || error "MCP_SERVERS requires jq"
  log "Merging MCP servers into opencode.json..."
  jq --argjson mcp "$MCP_SERVERS" '.mcp = $mcp' "$SITE_PATH/opencode.json" \
    > "$SITE_PATH/opencode.json.tmp" \
    && mv "$SITE_PATH/opencode.json.tmp" "$SITE_PATH/opencode.json"
}

runtime_install_hooks() {
  return
}

runtime_skills_dir() {
  echo "$SITE_PATH/.opencode/skills"
}

runtime_print_summary() {
  echo "OpenCode:"
  echo "  Config:   $SITE_PATH/opencode.json"
  if [ -n "$OPENCODE_MODEL" ]; then
    echo "  Model:    $OPENCODE_MODEL"
  else
    echo "  Model:    (OpenCode default — zen free models)"
  fi
  echo ""
}
