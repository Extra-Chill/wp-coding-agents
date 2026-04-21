#!/bin/bash
#
# wp-coding-agents upgrade script
# Safely upgrade a live wp-coding-agents install without touching user state.
#
# Phases:
#   1. Detect environment (auto-detects local vs VPS, runtime, chat bridge —
#      supports kimaki, cc-connect, telegram).
#   2. Sync chat-bridge config (dispatches per bridge)
#        kimaki:
#          VPS:   /opt/kimaki-config (plugins + post-upgrade.sh + kill list)
#          Local: $(npm root -g)/kimaki/plugins for plugins,
#                 $KIMAKI_DATA_DIR/kimaki-config/ for post-upgrade.sh + kill
#                 list, and runs post-upgrade.sh inline (no launchd
#                 ExecStartPre hook).
#        cc-connect: no per-install artifacts; reports binary version and
#          reminds user to `npm update -g cc-connect`.
#        telegram: no per-install artifacts; reports binary versions and
#          reminds user to `npm update -g @grinev/opencode-telegram-bot`.
#   3. Sync agent skills (WordPress + Data Machine)
#   4. Regenerate AGENTS.md via Data Machine compose
#   5. Smart systemd update (VPS only; dispatches per bridge)
#        kimaki     → kimaki.service
#        cc-connect → cc-connect.service
#        telegram   → opencode-serve.service + opencode-telegram.service
#      Each unit's existing Environment= lines are preserved (host custom
#      values, secrets) while structural lines are refreshed from the same
#      template as lib/chat-bridge.sh.
#   6. Re-apply opencode-claude-auth PascalCase patch (opencode runtime only)
#   7. Summary — prints the right restart + verify commands per bridge × env.
#
# Usage:
#   ./upgrade.sh                 # run all phases (auto-detects environment)
#   ./upgrade.sh --dry-run       # preview without changes
#   ./upgrade.sh --kimaki-only   # only sync kimaki config + plugins
#   ./upgrade.sh --skills-only   # only sync skills
#   ./upgrade.sh --agents-md-only  # only regenerate AGENTS.md
#   ./upgrade.sh --local --wp-path <path>  # local install (auto on macOS)
#
# Safety: NEVER touches WordPress DB, nginx, SSL, ~/.kimaki/ auth state,
#   the DM workspace cloned repos, agent memory files, or the running
#   chat-bridge service.
#
#   opencode.json is only touched when --repair-opencode-json is passed.
#   The repair surgically rewrites the `plugin` array to match what current
#   setup would produce for the detected (runtime, chat bridge, DM) combo,
#   preserving all other keys. A .backup.<ts> is written alongside. Without
#   the flag, drift is diagnosed and reported in the summary but not fixed.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Source shared modules (common, detect needed for environment resolution;
# wordpress is needed for wp_cmd helper used by compose; chat-bridges for
# systemd/launchd template generators shared with setup-time install).
for lib in common detect wordpress skills chat-bridges; do
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
REPAIR_OPENCODE_JSON=false
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
    --repair-opencode-json) REPAIR_OPENCODE_JSON=true; shift ;;
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
  ./upgrade.sh                  Run all phases (auto-detects local vs VPS)
  ./upgrade.sh --dry-run        Preview what would change
  ./upgrade.sh --kimaki-only    Only sync chat-bridge config (kept name for
                                backwards compat — also handles cc-connect
                                and telegram when they are the detected bridge)
  ./upgrade.sh --skills-only    Only sync agent skills
  ./upgrade.sh --agents-md-only Only regenerate AGENTS.md
  ./upgrade.sh --repair-opencode-json
                                Detect AND fix drift between opencode.json's
                                "plugin" array and what current setup would
                                produce. Writes a .backup.<ts> alongside.
                                Default behaviour: diagnose + warn only.
  ./upgrade.sh --runtime <name> Force runtime (auto-detected otherwise)
  ./upgrade.sh --wp-path <path> Override detected WordPress path
  ./upgrade.sh --local          Local mode (no systemd; auto-on on macOS)

SUPPORTED CHAT BRIDGES:
  kimaki, cc-connect, telegram  (auto-detected per environment)

KIMAKI PLUGIN INSTALL TARGETS:
  VPS:   /opt/kimaki-config/plugins
  Local: \$(npm root -g)/kimaki/plugins

NEVER TOUCHED:
  - CLAUDE.md runtime config
  - WordPress database, nginx, SSL certs
  - ~/.kimaki/ auth state and OAuth tokens
  - DM workspace cloned repos
  - Agent memory files (SOUL.md, MEMORY.md, USER.md, etc.)
  - Running chat-bridge service (never restarted automatically)

OPT-IN TOUCHES:
  - opencode.json — only with --repair-opencode-json. Rewrites the
    "plugin" array to match current setup output; preserves all other
    keys; writes a .backup.<ts> alongside.
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

# Run detect_environment first — it auto-sets LOCAL_MODE=true on macOS,
# which the chat bridge detection below depends on to pick the right branch.
detect_environment

# Detect chat bridge from installed services / installed binaries via the
# lib/chat-bridges.sh registry. See bridge_detect_local / bridge_detect_vps
# for the full probe order (launchd plists + command -v on local; systemd
# unit files on VPS). Priority: kimaki > cc-connect > telegram.
if [ "$LOCAL_MODE" = true ]; then
  CHAT_BRIDGE=$(bridge_detect_local)
else
  CHAT_BRIDGE=$(bridge_detect_vps)
fi

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

# Set true when opencode.json is found to have plugin-array drift and the
# --repair-opencode-json flag was NOT passed. Shown loudly in print_summary.
OPENCODE_JSON_DRIFT=false

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
# Phase 2: Sync chat-bridge config
#   kimaki    → plugins + post-upgrade.sh + skills-kill-list (see below).
#   cc-connect → no per-install artifacts beyond the npm package; config.toml
#                is user-owned. Report version and remind user to
#                `npm update -g cc-connect` for upstream updates.
#   telegram  → no per-install artifacts beyond the npm package; .env files
#                contain user secrets and are not touched. Report versions
#                and remind user to `npm update -g @grinev/opencode-telegram-bot`.
# ============================================================================

sync_chat_bridge_config() {
  _run_filter_active kimaki || return 0

  case "$CHAT_BRIDGE" in
    kimaki)     _sync_kimaki_config ;;
    cc-connect) _sync_cc_connect_config ;;
    telegram)   _sync_telegram_config ;;
    *) log "Phase 2: Skipping (no chat bridge detected)" ;;
  esac
}

_sync_cc_connect_config() {
  log "Phase 2: cc-connect detected — no per-install artifacts to sync."
  if command -v cc-connect &>/dev/null; then
    local cc_version
    cc_version=$(cc-connect --version 2>/dev/null | head -1 || echo "unknown")
    log "  cc-connect version: $cc_version"
  else
    warn "  cc-connect binary not on PATH"
  fi
  log "  To update upstream:  npm update -g cc-connect"
  log "  User config (never touched):  \$CC_DATA_DIR/config.toml (defaults to \$HOME/.cc-connect/config.toml)"
}

_sync_telegram_config() {
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

_sync_kimaki_config() {

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
      echo -e "${BLUE}[dry-run]${NC} Would bootstrap $KIMAKI_CONFIG_DIR from $SCRIPT_DIR/kimaki/"
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

  # Copy plugins to KIMAKI_PLUGINS_DIR (the path opencode.json actually loads from).
  if [ -d "$SCRIPT_DIR/kimaki/plugins" ]; then
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$KIMAKI_PLUGINS_DIR" 2>/dev/null || true
    fi
    for plugin_file in "$SCRIPT_DIR"/kimaki/plugins/*.ts; do
      [ -f "$plugin_file" ] || continue
      local name
      name=$(basename "$plugin_file")
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

  if [ -f "$SCRIPT_DIR/kimaki/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/post-upgrade.sh"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        cp "$SCRIPT_DIR/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        log "  Updated $KIMAKI_CONFIG_DIR/post-upgrade.sh"
        UPDATED_ITEMS+=("kimaki-config/post-upgrade.sh")
      fi
    fi
  fi

  if [ -f "$SCRIPT_DIR/kimaki/skills-kill-list.txt" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/skills-kill-list.txt"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt" 2>/dev/null; then
        cp "$SCRIPT_DIR/kimaki/skills-kill-list.txt" "$KIMAKI_CONFIG_DIR/skills-kill-list.txt"
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

  log "  Done."

  # Export resolved paths so print_summary can reference them
  RESOLVED_KIMAKI_CONFIG_DIR="$KIMAKI_CONFIG_DIR"
  RESOLVED_KIMAKI_PLUGINS_DIR="$KIMAKI_PLUGINS_DIR"
}

# ============================================================================
# Phase 2b: Detect + optionally repair opencode.json plugin drift
#
# opencode.json is user-owned (model settings, agent prompt files, permissions,
# etc.), so this phase is read-only by default. It compares the file's
# `plugin` array against what current setup would produce for the detected
# (RUNTIME, CHAT_BRIDGE, INSTALL_DATA_MACHINE) combo and surfaces drift.
#
# The most common drift vectors:
#   - install predates v0.4.0 (no `plugin` key at all)
#   - install predates #51 fix (stale `opencode-claude-auth@latest` on kimaki)
#   - new plugins added to setup.sh that the install never got
#
# With --repair-opencode-json, the `plugin` array is surgically rewritten to
# match the expected list. All other keys are preserved. A .backup.<ts> is
# written alongside.
#
# Non-opencode runtimes (claude-code, studio-code) are skipped silently —
# they use different config mechanisms.
# ============================================================================

check_opencode_json_drift() {
  # Only runs for opencode runtime. Silent skip on others.
  if [ "$RUNTIME" != "opencode" ]; then
    return 0
  fi

  local OPENCODE_JSON_FILE="$SITE_PATH/opencode.json"
  if [ ! -f "$OPENCODE_JSON_FILE" ]; then
    warn "Phase 2b: $OPENCODE_JSON_FILE not found — skipping drift check"
    return 0
  fi

  local HELPER="$SCRIPT_DIR/lib/repair-opencode-json.py"
  if [ ! -f "$HELPER" ]; then
    warn "Phase 2b: $HELPER not found — skipping drift check"
    return 0
  fi

  local BRIDGE_ARG="${CHAT_BRIDGE:-none}"
  local DM_ARG="false"
  [ "$INSTALL_DATA_MACHINE" = true ] && DM_ARG="true"

  # Kimaki plugins dir — match what _sync_kimaki_config resolved.
  local PLUGINS_DIR="${RESOLVED_KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"

  if [ "$REPAIR_OPENCODE_JSON" = true ]; then
    log "Phase 2b: Repairing opencode.json plugin array..."
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would run: python3 $HELPER --file $OPENCODE_JSON_FILE --runtime $RUNTIME --chat-bridge $BRIDGE_ARG --install-dm $DM_ARG --kimaki-plugins-dir $PLUGINS_DIR --apply"
      # Still show the diagnostic even in dry-run
      local dry_out
      dry_out=$(python3 "$HELPER" \
        --file "$OPENCODE_JSON_FILE" \
        --runtime "$RUNTIME" \
        --chat-bridge "$BRIDGE_ARG" \
        --install-dm "$DM_ARG" \
        --kimaki-plugins-dir "$PLUGINS_DIR" 2>&1 || true)
      echo "$dry_out" | sed 's/^/    /'
      return 0
    fi

    local out rc
    out=$(python3 "$HELPER" \
      --file "$OPENCODE_JSON_FILE" \
      --runtime "$RUNTIME" \
      --chat-bridge "$BRIDGE_ARG" \
      --install-dm "$DM_ARG" \
      --kimaki-plugins-dir "$PLUGINS_DIR" \
      --apply \
      --backup-suffix "$TIMESTAMP" 2>&1) && rc=0 || rc=$?

    local status
    status=$(echo "$out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','?'))" 2>/dev/null || echo "parse-error")

    case "$status" in
      ok)
        log "  opencode.json plugin array already correct"
        ;;
      repaired)
        log "  opencode.json repaired (backup: ${OPENCODE_JSON_FILE}.backup.$TIMESTAMP)"
        log "  $out"
        UPDATED_ITEMS+=("opencode.json plugin array (repaired)")
        ;;
      skipped)
        log "  $out"
        ;;
      *)
        warn "  repair-opencode-json.py returned status=$status (rc=$rc)"
        warn "  $out"
        ;;
    esac
    return 0
  fi

  # Diagnostic-only path (default).
  local out rc
  out=$(python3 "$HELPER" \
    --file "$OPENCODE_JSON_FILE" \
    --runtime "$RUNTIME" \
    --chat-bridge "$BRIDGE_ARG" \
    --install-dm "$DM_ARG" \
    --kimaki-plugins-dir "$PLUGINS_DIR" 2>&1) && rc=0 || rc=$?

  local status
  status=$(echo "$out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','?'))" 2>/dev/null || echo "parse-error")

  case "$status" in
    ok)
      log "Phase 2b: opencode.json plugin array matches current setup"
      ;;
    drift)
      warn "Phase 2b: opencode.json plugin array has drift — re-run with --repair-opencode-json to fix"
      warn "  $out"
      OPENCODE_JSON_DRIFT=true
      ;;
    skipped)
      log "Phase 2b: $out"
      ;;
    *)
      warn "Phase 2b: repair-opencode-json.py returned status=$status (rc=$rc)"
      warn "  $out"
      ;;
  esac
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
#   Dispatches per chat bridge. Each bridge regenerates its unit file(s) from
#   the same template as lib/chat-bridge.sh, preserves existing Environment=
#   lines, writes + daemon-reloads, NEVER restarts.
# ============================================================================

update_chat_bridge_systemd() {
  _run_filter_active systemd || return 0

  if [ "$LOCAL_MODE" = true ]; then
    log "Phase 5: Skipping (local mode — no systemd)"
    return 0
  fi

  case "$CHAT_BRIDGE" in
    kimaki)     _update_kimaki_systemd ;;
    cc-connect) _update_cc_connect_systemd ;;
    telegram)   _update_telegram_systemd ;;
    *) log "Phase 5: Skipping (no chat bridge detected)" ;;
  esac
}

# Helper: merge new Environment= lines from a template into the current unit,
# preserving every existing Environment= line the host has customised (e.g.
# BUN_INSTALL, custom PATH, secrets) and appending template keys that are
# missing. Returns the merged block on stdout.
_merge_systemd_env_lines() {
  local current_env="$1"
  local template_env="$2"
  local merged="$current_env"
  while IFS= read -r tmpl_line; do
    [ -z "$tmpl_line" ] && continue
    local key
    key=$(echo "$tmpl_line" | sed -n 's/^Environment=\([^=]*\)=.*/\1/p')
    [ -z "$key" ] && continue
    if ! echo "$current_env" | grep -q "^Environment=${key}="; then
      if [ -n "$merged" ]; then
        merged="$merged
$tmpl_line"
      else
        merged="$tmpl_line"
      fi
    fi
  done <<< "$template_env"
  echo "$merged"
}

# Helper: diff + write + daemon-reload a single systemd unit.
# Args: $1 unit path, $2 new unit content, $3 human label for summary line.
_smart_update_systemd_unit() {
  local unit_file="$1"
  local new_unit="$2"
  local label="${3:-$(basename "$unit_file")}"

  if [ ! -f "$unit_file" ]; then
    warn "  $unit_file does not exist — skipping"
    return 0
  fi

  if echo "$new_unit" | cmp -s - "$unit_file"; then
    log "  $(basename "$unit_file"): unchanged"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would update $unit_file"
    echo -e "${BLUE}[dry-run]${NC} Diff:"
    diff -u "$unit_file" <(echo "$new_unit") 2>/dev/null | head -30 | sed 's/^/    /' || true
    echo -e "${BLUE}[dry-run]${NC} Would run: systemctl daemon-reload"
    return 0
  fi

  cp "$unit_file" "${unit_file}.backup.$TIMESTAMP"
  echo "$new_unit" > "$unit_file"
  log "  Updated $unit_file (backup: ${unit_file}.backup.$TIMESTAMP)"
  log "  Diff:"
  diff -u "${unit_file}.backup.$TIMESTAMP" "$unit_file" 2>/dev/null | head -30 | sed 's/^/    /' || true
  systemctl daemon-reload
  log "  systemctl daemon-reload complete"
  log "  NOTE: $label NOT restarted — run the restart command in the summary when ready"
  UPDATED_ITEMS+=("$label (daemon-reloaded, not restarted)")
}

_update_kimaki_systemd() {
  log "Phase 5: Checking kimaki.service template..."

  local UNIT_FILE="/etc/systemd/system/kimaki.service"
  [ -f "$UNIT_FILE" ] || { warn "  $UNIT_FILE does not exist — skipping"; return 0; }

  local CURRENT_ENV
  CURRENT_ENV=$(grep '^Environment=' "$UNIT_FILE" || true)

  local KIMAKI_BIN
  KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/usr/bin/kimaki")
  local KIMAKI_CONFIG_DIR="/opt/kimaki-config"

  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"

  local MERGED_ENV
  MERGED_ENV=$(_merge_systemd_env_lines "$CURRENT_ENV" "$TEMPLATE_ENV")

  local NEW_UNIT
  NEW_UNIT=$(bridge_render_systemd kimaki kimaki.service "$MERGED_ENV")

  _smart_update_systemd_unit "$UNIT_FILE" "$NEW_UNIT" "kimaki.service"
}

_update_cc_connect_systemd() {
  log "Phase 5: Checking cc-connect.service template..."

  local UNIT_FILE="/etc/systemd/system/cc-connect.service"
  [ -f "$UNIT_FILE" ] || { warn "  $UNIT_FILE does not exist — skipping"; return 0; }

  local CURRENT_ENV
  CURRENT_ENV=$(grep '^Environment=' "$UNIT_FILE" || true)

  local CC_BIN
  CC_BIN=$(which cc-connect 2>/dev/null || echo "/usr/bin/cc-connect")

  # CC_CONNECT_TOKEN lives in the existing unit's env if setup originally
  # set it; mandatory template omits it and _merge_systemd_env_lines
  # preserves host-specific keys.
  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin"

  local MERGED_ENV
  MERGED_ENV=$(_merge_systemd_env_lines "$CURRENT_ENV" "$TEMPLATE_ENV")

  local NEW_UNIT
  NEW_UNIT=$(bridge_render_systemd cc-connect cc-connect.service "$MERGED_ENV")

  _smart_update_systemd_unit "$UNIT_FILE" "$NEW_UNIT" "cc-connect.service"
}

_update_telegram_systemd() {
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
    SERVE_NEW=$(bridge_render_systemd telegram opencode-serve.service "$SERVE_MERGED_ENV")
    _smart_update_systemd_unit "$SERVE_UNIT" "$SERVE_NEW" "opencode-serve.service"
  else
    warn "  $SERVE_UNIT does not exist — skipping"
  fi

  # --- opencode-telegram.service ---
  if [ -f "$TG_UNIT" ]; then
    local TG_CURRENT_ENV TG_MERGED_ENV TG_NEW
    TG_CURRENT_ENV=$(grep '^Environment=' "$TG_UNIT" || true)
    TG_MERGED_ENV=$(_merge_systemd_env_lines "$TG_CURRENT_ENV" "$TEMPLATE_ENV")
    TG_NEW=$(bridge_render_systemd telegram opencode-telegram.service "$TG_MERGED_ENV")
    _smart_update_systemd_unit "$TG_UNIT" "$TG_NEW" "opencode-telegram.service"
  else
    warn "  $TG_UNIT does not exist — skipping"
  fi
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

  if [ "$OPENCODE_JSON_DRIFT" = true ]; then
    echo ""
    warn "opencode.json plugin-array drift detected."
    warn "  Re-run with: ./upgrade.sh --repair-opencode-json"
    warn "  (Drift is common on installs that predate #51 or v0.4.0.)"
  fi

  echo ""
  _print_bridge_restart_hint
  _print_verify_block
}

# Print the correct restart command for the detected chat bridge × environment.
_print_bridge_restart_hint() {
  case "$CHAT_BRIDGE" in
    kimaki)
      if [ "$LOCAL_MODE" = true ]; then
        warn "Restart kimaki when ready (active chat sessions will die):"
        if [ -f "$HOME/Library/LaunchAgents/com.wp.kimaki.plist" ]; then
          warn "  launchctl kickstart -k gui/$(id -u)/com.wp.kimaki"
        else
          warn "  Stop your kimaki process and re-run: cd $SITE_PATH && kimaki"
        fi
      else
        warn "Restart kimaki when ready: systemctl restart kimaki"
        warn "  (Active sessions will die when you restart.)"
      fi
      echo ""
      ;;
    cc-connect)
      if [ "$LOCAL_MODE" = true ]; then
        warn "Restart cc-connect when ready (active chat sessions will die):"
        if [ -f "$HOME/Library/LaunchAgents/com.wp.cc-connect.plist" ]; then
          warn "  launchctl kickstart -k gui/$(id -u)/com.wp.cc-connect"
        else
          warn "  Stop your cc-connect process and re-run: cd $SITE_PATH && cc-connect"
        fi
      else
        warn "Restart cc-connect when ready: systemctl restart cc-connect"
        warn "  (Active sessions will die when you restart.)"
      fi
      echo ""
      ;;
    telegram)
      if [ "$LOCAL_MODE" = true ]; then
        warn "Restart telegram stack when ready (active chat sessions will die):"
        if [ -f "$HOME/Library/LaunchAgents/com.wp.opencode-serve.plist" ]; then
          warn "  launchctl kickstart -k gui/$(id -u)/com.wp.opencode-serve"
          warn "  launchctl kickstart -k gui/$(id -u)/com.wp.opencode-telegram"
        else
          warn "  Stop your opencode serve + opencode-telegram processes and restart manually"
        fi
      else
        warn "Restart telegram stack when ready:"
        warn "  systemctl restart opencode-serve opencode-telegram"
        warn "  (Active sessions will die when you restart.)"
      fi
      echo ""
      ;;
  esac
}

_print_verify_block() {
  log "Verify:"
  case "$CHAT_BRIDGE" in
    kimaki)
      if [ "$LOCAL_MODE" = true ]; then
        if [ -f "$HOME/Library/LaunchAgents/com.wp.kimaki.plist" ]; then
          log "  launchctl print gui/$(id -u)/com.wp.kimaki | head -20   # chat bridge status"
        else
          log "  pgrep -fl kimaki                                        # chat bridge status"
        fi
      else
        log "  systemctl status kimaki                                  # chat bridge status"
      fi
      local PLUGINS_DIR="${RESOLVED_KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"
      log "  ls $PLUGINS_DIR   # plugin versions"
      ;;
    cc-connect)
      if [ "$LOCAL_MODE" = true ]; then
        if [ -f "$HOME/Library/LaunchAgents/com.wp.cc-connect.plist" ]; then
          log "  launchctl print gui/$(id -u)/com.wp.cc-connect | head -20   # chat bridge status"
        else
          log "  pgrep -fl cc-connect                                        # chat bridge status"
        fi
      else
        log "  systemctl status cc-connect                                 # chat bridge status"
      fi
      log "  cc-connect --version                                        # binary version"
      ;;
    telegram)
      if [ "$LOCAL_MODE" = true ]; then
        log "  launchctl print gui/$(id -u)/com.wp.opencode-serve | head -20     # opencode-serve status"
        log "  launchctl print gui/$(id -u)/com.wp.opencode-telegram | head -20  # telegram bot status"
      else
        log "  systemctl status opencode-serve opencode-telegram           # chat bridge status"
      fi
      log "  opencode-telegram --version                                 # binary version"
      ;;
    *)
      log "  (no chat bridge detected)"
      ;;
  esac
  log "  cat $SITE_PATH/AGENTS.md | head -20   # agent instructions"
  log "  ls $(runtime_skills_dir)              # installed skills"
}

# ============================================================================
# Execute
# ============================================================================

sync_chat_bridge_config
check_opencode_json_drift
sync_skills
regenerate_agents_md
update_chat_bridge_systemd
reapply_claude_auth_patch
print_summary
