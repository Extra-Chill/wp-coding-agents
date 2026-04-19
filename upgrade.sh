#!/bin/bash
#
# wp-coding-agents upgrade script
# Safely upgrade a live wp-coding-agents install without touching user state.
#
# Phases:
#   1. Detect environment
#   2. Sync kimaki-config (plugins, post-upgrade.sh, skills-kill-list)
#   3. Sync agent skills (WordPress + Data Machine)
#   4. Regenerate AGENTS.md via Data Machine compose
#   5. Smart systemd update (merges host-specific Environment= lines)
#   6. Re-apply opencode-claude-auth PascalCase patch
#   7. Summary
#
# Usage:
#   ./upgrade.sh                 # run all phases
#   ./upgrade.sh --dry-run       # preview without changes
#   ./upgrade.sh --kimaki-only   # only sync /opt/kimaki-config
#   ./upgrade.sh --skills-only   # only sync skills
#   ./upgrade.sh --agents-md-only  # only regenerate AGENTS.md
#
# Safety: NEVER touches opencode.json, WordPress DB, nginx, SSL,
#   ~/.kimaki/ auth state, /var/lib/datamachine/workspace/ repos,
#   agent memory files, or the running kimaki service.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Source shared modules (common, detect needed for environment resolution;
# wordpress is needed for wp_cmd helper used by compose).
for lib in common detect wordpress skills; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

# Discover available runtimes
AVAILABLE_RUNTIMES=()
for runtime_file in "$SCRIPT_DIR"/runtimes/*.sh; do
  [ -f "$runtime_file" ] || continue
  AVAILABLE_RUNTIMES+=("$(basename "$runtime_file" .sh)")
done

# ============================================================================
# Parse arguments
# ============================================================================

DRY_RUN=false
KIMAKI_ONLY=false
SKILLS_ONLY=false
AGENTS_MD_ONLY=false
SHOW_HELP=false

# Defaults setup.sh expects (detect.sh reads these)
LOCAL_MODE=false
SKIP_DEPS=true
SKIP_SSL=true
INSTALL_DATA_MACHINE=true
INSTALL_CHAT=true
INSTALL_SKILLS=true
RUN_AS_ROOT=true
MULTISITE=false
MULTISITE_TYPE="subdirectory"
MODE="existing"
RUNTIME=""
IS_STUDIO=false
CHAT_BRIDGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)       DRY_RUN=true; shift ;;
    --kimaki-only)   KIMAKI_ONLY=true; shift ;;
    --skills-only)   SKILLS_ONLY=true; shift ;;
    --agents-md-only) AGENTS_MD_ONLY=true; shift ;;
    --runtime)       RUNTIME="$2"; shift 2 ;;
    --wp-path)       EXISTING_WP="$2"; shift 2 ;;
    --local)         LOCAL_MODE=true; RUN_AS_ROOT=false; shift ;;
    --help|-h)       SHOW_HELP=true; shift ;;
    *)               shift ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << HELP
wp-coding-agents upgrade script

Safely upgrade a live install without touching user state.

USAGE:
  ./upgrade.sh                  Run all phases
  ./upgrade.sh --dry-run        Preview what would change
  ./upgrade.sh --kimaki-only    Only sync /opt/kimaki-config
  ./upgrade.sh --skills-only    Only sync agent skills
  ./upgrade.sh --agents-md-only Only regenerate AGENTS.md
  ./upgrade.sh --runtime <name> Force runtime (auto-detected otherwise)
  ./upgrade.sh --wp-path <path> Override detected WordPress path
  ./upgrade.sh --local          Local mode (no systemd, no service user)

NEVER TOUCHED:
  - opencode.json / CLAUDE.md runtime config
  - WordPress database, nginx, SSL certs
  - ~/.kimaki/ auth state and OAuth tokens
  - /var/lib/datamachine/workspace/ cloned repos
  - Agent memory files (SOUL.md, MEMORY.md, USER.md, etc.)
  - Running kimaki service (never restarted automatically)
HELP
  exit 0
fi

# ============================================================================
# Phase 1: Detect environment
# ============================================================================

log "Phase 1: Detecting environment..."

# Auto-detect EXISTING_WP if not provided.
# Priority: env var → scan /var/www for wp-config.php → fail.
if [ -z "$EXISTING_WP" ]; then
  if [ "$LOCAL_MODE" = true ]; then
    error "Local mode requires --wp-path <path> or EXISTING_WP env var"
  fi

  # Scan /var/www for the first WordPress install
  for candidate in /var/www/*/; do
    if [ -f "$candidate/wp-config.php" ]; then
      EXISTING_WP="${candidate%/}"
      log "Auto-detected WordPress at: $EXISTING_WP"
      break
    fi
  done

  if [ -z "$EXISTING_WP" ]; then
    error "Could not auto-detect WordPress path. Pass --wp-path <path> or set EXISTING_WP."
  fi
fi

# Auto-detect runtime (same logic as setup.sh)
if [ -z "$RUNTIME" ]; then
  if command -v studio &>/dev/null && [ -f "$EXISTING_WP/STUDIO.md" ]; then
    RUNTIME="studio-code"
  elif command -v opencode &>/dev/null; then
    RUNTIME="opencode"
  elif command -v claude &>/dev/null; then
    RUNTIME="claude-code"
  else
    warn "No runtime binary found — defaulting to opencode"
    RUNTIME="opencode"
  fi
fi

RUNTIME_FILE="$SCRIPT_DIR/runtimes/${RUNTIME}.sh"
if [ ! -f "$RUNTIME_FILE" ]; then
  error "Unknown runtime: $RUNTIME. Available: ${AVAILABLE_RUNTIMES[*]}"
fi
source "$RUNTIME_FILE"

# Detect chat bridge from installed services
if [ -f "/etc/systemd/system/kimaki.service" ]; then
  CHAT_BRIDGE="kimaki"
elif [ -f "/etc/systemd/system/cc-connect.service" ]; then
  CHAT_BRIDGE="cc-connect"
elif [ -f "/etc/systemd/system/opencode-telegram.service" ]; then
  CHAT_BRIDGE="telegram"
fi

# Run detect_environment — populates SITE_PATH, SERVICE_USER, etc.
detect_environment

log "Runtime:     $RUNTIME"
log "Chat bridge: ${CHAT_BRIDGE:-none detected}"
log "Site path:   $SITE_PATH"
log "Service:     $SERVICE_USER"
if [ "$DRY_RUN" = true ]; then
  log "Dry-run mode: no changes will be made"
fi
echo ""

# Track what was touched for the summary
UPDATED_ITEMS=()

# ============================================================================
# Helpers
# ============================================================================

_run_filter_active() {
  # Returns 0 if the given phase should run given the *-only flags.
  # Usage: _run_filter_active <flag_name>   (e.g. KIMAKI_ONLY)
  local phase="$1"
  # If any --*-only flag is set, only that one runs
  if [ "$KIMAKI_ONLY" = true ] || [ "$SKILLS_ONLY" = true ] || [ "$AGENTS_MD_ONLY" = true ]; then
    case "$phase" in
      kimaki)    [ "$KIMAKI_ONLY" = true ] ;;
      skills)    [ "$SKILLS_ONLY" = true ] ;;
      agents-md) [ "$AGENTS_MD_ONLY" = true ] ;;
      systemd|patch) return 1 ;;  # infrastructure phases skipped in *-only modes
      *)         return 1 ;;
    esac
  else
    return 0
  fi
}

# ============================================================================
# Phase 2: Sync /opt/kimaki-config (plugins, post-upgrade.sh, skills-kill-list)
# ============================================================================

sync_kimaki_config() {
  _run_filter_active kimaki || return 0

  if [ "$CHAT_BRIDGE" != "kimaki" ]; then
    log "Phase 2: Skipping (kimaki is not the chat bridge)"
    return 0
  fi

  log "Phase 2: Syncing /opt/kimaki-config..."

  local KIMAKI_CONFIG_DIR="/opt/kimaki-config"
  local BACKUP_DIR="/opt/kimaki-config.backup.$TIMESTAMP"

  if [ ! -d "$KIMAKI_CONFIG_DIR" ]; then
    warn "  $KIMAKI_CONFIG_DIR does not exist — nothing to sync"
    return 0
  fi

  # Backup current state
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would backup $KIMAKI_CONFIG_DIR → $BACKUP_DIR"
  else
    cp -r "$KIMAKI_CONFIG_DIR" "$BACKUP_DIR"
    log "  Backup created: $BACKUP_DIR"
  fi

  # Copy plugins
  if [ -d "$SCRIPT_DIR/kimaki/plugins" ]; then
    mkdir -p "$KIMAKI_CONFIG_DIR/plugins" 2>/dev/null || true
    for plugin_file in "$SCRIPT_DIR"/kimaki/plugins/*.ts; do
      [ -f "$plugin_file" ] || continue
      local name
      name=$(basename "$plugin_file")
      if [ "$DRY_RUN" = true ]; then
        if ! cmp -s "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name" 2>/dev/null; then
          echo -e "${BLUE}[dry-run]${NC} Would update plugins/$name"
        else
          echo -e "${BLUE}[dry-run]${NC} plugins/$name: unchanged"
        fi
      else
        if ! cmp -s "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name" 2>/dev/null; then
          cp "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name"
          log "  Updated plugins/$name"
          UPDATED_ITEMS+=("kimaki-config/plugins/$name")
        fi
      fi
    done
  fi

  # Copy post-upgrade.sh
  if [ -f "$SCRIPT_DIR/kimaki/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update post-upgrade.sh"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        cp "$SCRIPT_DIR/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        log "  Updated post-upgrade.sh"
        UPDATED_ITEMS+=("kimaki-config/post-upgrade.sh")
      fi
    fi
  fi

  # Copy skills-kill-list.txt
  if [ -f "$SCRIPT_DIR/kimaki/skills-kill-list.txt" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update skills-kill-list.txt"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt" 2>/dev/null; then
        cp "$SCRIPT_DIR/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt"
        log "  Updated skills-kill-list.txt"
        UPDATED_ITEMS+=("kimaki-config/skills-kill-list.txt")
      fi
    fi
  fi

  log "  Done."
}

# ============================================================================
# Phase 3: Sync agent skills (WordPress + Data Machine)
# ============================================================================

sync_skills() {
  _run_filter_active skills || return 0

  log "Phase 3: Syncing agent skills..."

  if [ "$DRY_RUN" = true ]; then
    SKILLS_DIR="$(runtime_skills_dir)"
    echo -e "${BLUE}[dry-run]${NC} Would clone WordPress/agent-skills → $SKILLS_DIR"
    if [ "$INSTALL_DATA_MACHINE" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would clone Extra-Chill/data-machine-skills → $SKILLS_DIR"
    fi
    if [ "$CHAT_BRIDGE" = "kimaki" ]; then
      echo -e "${BLUE}[dry-run]${NC} Would copy skills to kimaki skills dir"
    fi
    return 0
  fi

  install_skills
  UPDATED_ITEMS+=("agent skills")
}

# ============================================================================
# Phase 4: Regenerate AGENTS.md
# ============================================================================

regenerate_agents_md() {
  _run_filter_active agents-md || return 0

  log "Phase 4: Regenerating AGENTS.md..."

  local AGENTS_MD="$SITE_PATH/AGENTS.md"
  local BACKUP="$SITE_PATH/AGENTS.md.backup.$TIMESTAMP"

  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    warn "  Data Machine not installed — skipping (nothing to compose)"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would backup $AGENTS_MD → $BACKUP"
    echo -e "${BLUE}[dry-run]${NC} Would run: $WP_CMD datamachine agent compose AGENTS.md $WP_ROOT_FLAG"
    return 0
  fi

  # Backup existing (compose writes in-place to the registered location)
  if [ -f "$AGENTS_MD" ]; then
    cp "$AGENTS_MD" "$BACKUP"
    log "  Backup: $BACKUP"
  fi

  # `datamachine agent compose AGENTS.md` writes in-place to the registered
  # composable file path. It does NOT accept an arbitrary output path —
  # the filename must be a registered MemoryFileRegistry entry.
  if (cd "$SITE_PATH" && $WP_CMD datamachine agent compose AGENTS.md $WP_ROOT_FLAG >/dev/null 2>&1); then
    if [ -f "$BACKUP" ] && cmp -s "$BACKUP" "$AGENTS_MD"; then
      log "  AGENTS.md unchanged"
      rm -f "$BACKUP" 2>/dev/null || true
    else
      log "  AGENTS.md regenerated"
      if [ -f "$BACKUP" ]; then
        log "  Diff (first 40 lines):"
        diff -u "$BACKUP" "$AGENTS_MD" 2>/dev/null | head -40 | sed 's/^/    /' || true
      fi
      UPDATED_ITEMS+=("AGENTS.md")
    fi
  else
    warn "  datamachine agent compose failed — AGENTS.md unchanged"
    # Restore from backup if compose wrote a partial file
    if [ -f "$BACKUP" ] && [ -f "$AGENTS_MD" ] && ! cmp -s "$BACKUP" "$AGENTS_MD"; then
      cp "$BACKUP" "$AGENTS_MD"
      warn "  Restored AGENTS.md from backup"
    fi
  fi
}

# ============================================================================
# Phase 5: Smart systemd update (merges host-specific Environment= lines)
# ============================================================================

update_kimaki_systemd() {
  _run_filter_active systemd || return 0

  if [ "$CHAT_BRIDGE" != "kimaki" ]; then
    log "Phase 5: Skipping (kimaki is not the chat bridge)"
    return 0
  fi

  if [ "$LOCAL_MODE" = true ]; then
    log "Phase 5: Skipping (local mode — no systemd)"
    return 0
  fi

  log "Phase 5: Checking kimaki.service template..."

  local UNIT_FILE="/etc/systemd/system/kimaki.service"
  if [ ! -f "$UNIT_FILE" ]; then
    warn "  $UNIT_FILE does not exist — skipping"
    return 0
  fi

  # Extract current Environment= lines (preserves host customizations like BUN_INSTALL)
  local CURRENT_ENV
  CURRENT_ENV=$(grep '^Environment=' "$UNIT_FILE" || true)

  # Generate fresh unit template (mirrors _install_kimaki_systemd in lib/chat-bridge.sh)
  local KIMAKI_BIN
  KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/usr/bin/kimaki")
  local KIMAKI_CONFIG_DIR="/opt/kimaki-config"

  # Default template Environment lines
  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"

  # Merge: start with current env, add template keys that are missing.
  # This preserves host-specific lines (BUN_INSTALL, custom PATH) AND
  # ensures required vars (KIMAKI_DATA_DIR) are present.
  local MERGED_ENV="$CURRENT_ENV"
  while IFS= read -r tmpl_line; do
    [ -z "$tmpl_line" ] && continue
    # Extract key: Environment=KEY=value → KEY
    local key
    key=$(echo "$tmpl_line" | sed -n 's/^Environment=\([^=]*\)=.*/\1/p')
    [ -z "$key" ] && continue
    # If not already present, append
    if ! echo "$CURRENT_ENV" | grep -q "^Environment=${key}="; then
      MERGED_ENV="$MERGED_ENV
$tmpl_line"
    fi
  done <<< "$TEMPLATE_ENV"

  # Build the fresh unit
  local NEW_UNIT="[Unit]
Description=Kimaki Discord Bot (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$MERGED_ENV
ExecStartPre=$KIMAKI_CONFIG_DIR/post-upgrade.sh
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

  # Compare
  if echo "$NEW_UNIT" | cmp -s - "$UNIT_FILE"; then
    log "  kimaki.service: unchanged"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would update $UNIT_FILE"
    echo -e "${BLUE}[dry-run]${NC} Diff:"
    diff -u "$UNIT_FILE" <(echo "$NEW_UNIT") 2>/dev/null | head -30 | sed 's/^/    /' || true
    echo -e "${BLUE}[dry-run]${NC} Would run: systemctl daemon-reload"
    return 0
  fi

  # Backup and write
  cp "$UNIT_FILE" "${UNIT_FILE}.backup.$TIMESTAMP"
  echo "$NEW_UNIT" > "$UNIT_FILE"
  log "  Updated $UNIT_FILE (backup: ${UNIT_FILE}.backup.$TIMESTAMP)"
  log "  Diff:"
  diff -u "${UNIT_FILE}.backup.$TIMESTAMP" "$UNIT_FILE" 2>/dev/null | head -30 | sed 's/^/    /' || true
  systemctl daemon-reload
  log "  systemctl daemon-reload complete"
  log "  NOTE: kimaki.service NOT restarted — run 'systemctl restart kimaki' when ready"
  UPDATED_ITEMS+=("kimaki.service (daemon-reloaded, not restarted)")
}

# ============================================================================
# Phase 6: Re-apply opencode-claude-auth PascalCase patch
# ============================================================================

reapply_claude_auth_patch() {
  _run_filter_active patch || return 0

  if [ "$RUNTIME" != "opencode" ]; then
    log "Phase 6: Skipping (runtime is $RUNTIME, not opencode)"
    return 0
  fi

  log "Phase 6: Re-applying opencode-claude-auth PascalCase patch..."

  if [ ! -f "$SCRIPT_DIR/lib/patch-claude-auth.py" ]; then
    warn "  patch-claude-auth.py not found — skipping"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would run: python3 $SCRIPT_DIR/lib/patch-claude-auth.py"
    return 0
  fi

  # The patch script is idempotent — already-patched is a no-op.
  local patch_output
  if patch_output=$(python3 "$SCRIPT_DIR/lib/patch-claude-auth.py" 2>&1); then
    log "  $patch_output"
    if echo "$patch_output" | grep -q "Patched successfully"; then
      UPDATED_ITEMS+=("opencode-claude-auth (PascalCase patch)")
    fi
  else
    warn "  Patch failed: $patch_output"
  fi
}

# ============================================================================
# Phase 7: Summary
# ============================================================================

print_summary() {
  echo ""
  echo "=========================================="
  log "Upgrade complete."
  echo "=========================================="

  if [ ${#UPDATED_ITEMS[@]} -eq 0 ]; then
    log "Nothing changed — everything was already up to date."
  else
    log "Updated:"
    for item in "${UPDATED_ITEMS[@]}"; do
      log "  - $item"
    done
  fi

  echo ""
  if [ "$CHAT_BRIDGE" = "kimaki" ] && [ "$LOCAL_MODE" = false ]; then
    warn "Restart kimaki when ready: systemctl restart kimaki"
    warn "  (Active sessions will die when you restart.)"
    echo ""
  fi

  log "Verify:"
  log "  systemctl status kimaki           # chat bridge status"
  log "  ls $KIMAKI_CONFIG_DIR/plugins     # plugin versions"
  log "  cat $SITE_PATH/AGENTS.md | head -20  # agent instructions"
  log "  ls $(runtime_skills_dir)          # installed skills"
}

# ============================================================================
# Execute
# ============================================================================

# Export vars expected by skills.sh
KIMAKI_CONFIG_DIR="/opt/kimaki-config"

sync_kimaki_config
sync_skills
regenerate_agents_md
update_kimaki_systemd
reapply_claude_auth_patch
print_summary
