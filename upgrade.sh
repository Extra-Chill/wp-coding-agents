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
#   opencode.json is touched by default in additive mode: managed plugin
#   entries the user is missing get added (dm-context-filter.ts,
#   dm-agent-sync.ts, opencode-claude-auth@latest — whichever apply), and
#   legacy `agent.build.prompt`/`agent.plan.prompt` keys get migrated to a
#   top-level `instructions` array (fixes Anthropic Claude Max OAuth, see
#   wp-coding-agents#60). User-added plugin entries are left alone.
#
#   --repair-opencode-json upgrades the repair to full reconciliation:
#   the `plugin` array is replaced with exactly what setup would produce
#   today, removing any unexpected entries in addition to the additive
#   behaviour above. Use this when you've intentionally pruned plugins
#   the user added by hand.
#
#   A .backup.<ts> is written alongside in both modes.
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
INSTALL_CHAT=true
INSTALL_SKILLS=true
RUN_AS_ROOT=true
MULTISITE=false
MULTISITE_TYPE="subdirectory"
MODE="existing"
RUNTIME=""
DETECTED_RUNTIMES=()
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
                                Full reconciliation of opencode.json:
                                - plugin array → match current setup exactly
                                  (adds missing + removes unexpected)
                                - agent.build.prompt → instructions array
                                  (fixes Anthropic Claude Max OAuth, #60)
                                Writes a .backup.<ts> alongside.
                                Default upgrade behaviour is additive repair:
                                only adds missing managed entries, never
                                removes user-added plugins.
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

DEFAULT TOUCHES:
  - opencode.json — additive repair. Adds managed plugin entries the
    user is missing (dm-context-filter.ts, dm-agent-sync.ts,
    opencode-claude-auth@latest — whichever apply to the detected runtime
    + chat bridge) and migrates "agent.build.prompt" to top-level
    "instructions" (fixes Anthropic Claude Max OAuth). Never removes
    user-added plugins. Preserves all other keys.
    Writes a .backup.<ts> alongside.

OPT-IN TOUCHES:
  - opencode.json (--repair-opencode-json) — full reconcile. In addition
    to the additive behaviour above, removes unexpected plugin entries
    so the array matches exactly what setup would produce today.
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

# Auto-detect runtime(s). Same model as setup.sh: DETECTED_RUNTIMES is the
# full list (drives multi-runtime skills install); RUNTIME is the primary
# (first-match cascade). Explicit --runtime narrows to a single runtime.
if [ -n "$RUNTIME" ]; then
  DETECTED_RUNTIMES=("$RUNTIME")
else
  if command -v studio &>/dev/null && [ -f "$EXISTING_WP/STUDIO.md" ]; then
    DETECTED_RUNTIMES+=("studio-code")
  fi
  if command -v claude &>/dev/null; then
    DETECTED_RUNTIMES+=("claude-code")
  fi
  if command -v opencode &>/dev/null; then
    DETECTED_RUNTIMES+=("opencode")
  fi
  if [ ${#DETECTED_RUNTIMES[@]} -eq 0 ]; then
    warn "No runtime binary found — defaulting to opencode"
    DETECTED_RUNTIMES=("opencode")
  fi
  RUNTIME="${DETECTED_RUNTIMES[0]}"
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
  if [ -d "$SCRIPT_DIR/kimaki/plugins" ]; then
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins" 2>/dev/null || true
      mkdir -p "$KIMAKI_PLUGINS_DIR" 2>/dev/null || true
    fi
    for plugin_file in "$SCRIPT_DIR"/kimaki/plugins/*.ts; do
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
# Phase 2b: Detect + optionally repair opencode.json drift
#
# opencode.json is user-owned (model settings, agent prompt files, permissions,
# etc.), so this phase is read-only by default. It compares the file against
# what current setup would produce and surfaces drift.
#
# Drift vectors checked:
#   1. `plugin` array — matches expected plugins for the detected runtime
#      and chat bridge. Only applies when runtime is opencode.
#   2. `agent.build.prompt` / `agent.plan.prompt` — legacy format that
#      breaks Anthropic Claude Max OAuth (see wp-coding-agents#60). Migrated
#      to a top-level `instructions` array. This check runs for ALL runtimes
#      because opencode.json can exist even when the primary runtime is
#      claude-code (e.g. kimaki spawns opencode sessions).
#
# With --repair-opencode-json, both drift vectors are repaired surgically.
# All other keys are preserved. A .backup.<ts> is written alongside.
# ============================================================================

check_opencode_json_drift() {
  # Runs whenever opencode.json exists on disk. Default behaviour is
  # additive repair: managed plugin entries the user is missing get added
  # (dm-context-filter.ts, dm-agent-sync.ts, opencode-claude-auth@latest —
  # whichever apply to the detected runtime + chat bridge), and legacy
  # agent.build.prompt / agent.plan.prompt get migrated to a top-level
  # `instructions` array (fixes Anthropic Claude Max OAuth,
  # wp-coding-agents#60).
  #
  # User-added plugin entries are left alone in additive mode. If any are
  # present after the repair the user is told to re-run with
  # --repair-opencode-json for the full reconciliation, which removes
  # unexpected entries too.
  #
  # Why additive is the default: dm-context-filter.ts is a security policy
  # plugin (it strips cross-channel routing discovery from Kimaki system
  # prompts). Installs that predate the filter, or were bootstrapped before
  # kimaki was the chat bridge, must not be left without it just because
  # the user never knew to pass an opt-in flag. See wp-coding-agents#67.

  local OPENCODE_JSON_FILE="$SITE_PATH/opencode.json"
  if [ ! -f "$OPENCODE_JSON_FILE" ]; then
    return 0
  fi

  local HELPER="$SCRIPT_DIR/lib/repair-opencode-json.py"
  if [ ! -f "$HELPER" ]; then
    warn "Phase 2b: $HELPER not found — skipping drift check"
    return 0
  fi

  local BRIDGE_ARG="${CHAT_BRIDGE:-none}"

  # Kimaki plugins dir — match what _sync_kimaki_config resolved.
  local PLUGINS_DIR="${RESOLVED_KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"

  # Runtime arg for repair-opencode-json.py: always `opencode` when the file
  # exists. The primary RUNTIME may be `studio-code` or `claude-code` (e.g.
  # on Studio sites where all three runtimes are detected), but the presence
  # of opencode.json on disk means opencode IS in use — otherwise the file
  # wouldn't be there. expected_plugins() skips plugin-array drift entirely
  # for non-opencode runtimes, which would silently mask real drift here.
  local RUNTIME_ARG="opencode"

  # Mode: --apply (full reconcile, opt-in) or --additive (default).
  local MODE_FLAG="--additive"
  local MODE_LABEL="additive repair"
  if [ "$REPAIR_OPENCODE_JSON" = true ]; then
    MODE_FLAG="--apply"
    MODE_LABEL="full repair"
  fi

  log "Phase 2b: opencode.json $MODE_LABEL..."

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would run: python3 $HELPER --file $OPENCODE_JSON_FILE --runtime $RUNTIME_ARG --chat-bridge $BRIDGE_ARG --kimaki-plugins-dir $PLUGINS_DIR $MODE_FLAG"
    local dry_out
    dry_out=$(python3 "$HELPER" \
      --file "$OPENCODE_JSON_FILE" \
      --runtime "$RUNTIME_ARG" \
      --chat-bridge "$BRIDGE_ARG" \
      --kimaki-plugins-dir "$PLUGINS_DIR" 2>&1 || true)
    echo "$dry_out" | sed 's/^/    /'
    return 0
  fi

  local repair_out repair_rc
  repair_out=$(python3 "$HELPER" \
    --file "$OPENCODE_JSON_FILE" \
    --runtime "$RUNTIME_ARG" \
    --chat-bridge "$BRIDGE_ARG" \
    --kimaki-plugins-dir "$PLUGINS_DIR" \
    "$MODE_FLAG" \
    --backup-suffix "$TIMESTAMP" 2>&1) && repair_rc=0 || repair_rc=$?

  local repair_status prompt_migration
  repair_status=$(echo "$repair_out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','?'))" 2>/dev/null || echo "parse-error")
  prompt_migration=$(echo "$repair_out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('prompt_migration','?'))" 2>/dev/null || echo "?")

  case "$repair_status" in
    ok)
      log "  opencode.json already correct"
      ;;
    additive_repaired)
      log "  opencode.json repaired additively (backup: ${OPENCODE_JSON_FILE}.backup.$TIMESTAMP)"
      log "  $repair_out"
      if [ "$prompt_migration" = "migrated" ]; then
        UPDATED_ITEMS+=("opencode.json prompt → instructions migration")
      fi
      UPDATED_ITEMS+=("opencode.json plugin array (added missing managed entries)")
      ;;
    needs_full_repair)
      warn "  opencode.json additively repaired, but unexpected plugin entries remain"
      warn "  Run './upgrade.sh --repair-opencode-json' to remove them (backup: ${OPENCODE_JSON_FILE}.backup.$TIMESTAMP)"
      warn "  $repair_out"
      if [ "$prompt_migration" = "migrated" ]; then
        UPDATED_ITEMS+=("opencode.json prompt → instructions migration")
      fi
      UPDATED_ITEMS+=("opencode.json plugin array (added managed entries; unexpected entries still present)")
      OPENCODE_JSON_DRIFT=true
      ;;
    repaired)
      log "  opencode.json fully repaired (backup: ${OPENCODE_JSON_FILE}.backup.$TIMESTAMP)"
      log "  $repair_out"
      if [ "$prompt_migration" = "migrated" ]; then
        UPDATED_ITEMS+=("opencode.json prompt → instructions migration")
      fi
      UPDATED_ITEMS+=("opencode.json plugin array (repaired)")
      ;;
    drift)
      # Only reachable if we passed neither --apply nor --additive, which
      # shouldn't happen with the dispatch above. Defensive.
      warn "Phase 2b: opencode.json has drift — $repair_out"
      OPENCODE_JSON_DRIFT=true
      ;;
    skipped)
      log "  $repair_out"
      ;;
    *)
      warn "  repair-opencode-json.py returned status=$repair_status (rc=$repair_rc)"
      warn "  $repair_out"
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
    echo -e "${BLUE}[dry-run]${NC} Would install in-repo skills from $SCRIPT_DIR/skills → $SKILLS_DIR"
    echo -e "${BLUE}[dry-run]${NC} Would clone WordPress/agent-skills → $SKILLS_DIR"
    echo -e "${BLUE}[dry-run]${NC} Would clone Extra-Chill/data-machine-skills → $SKILLS_DIR"
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

update_chat_bridge_launchd() {
  if [ "$LOCAL_MODE" != true ] || [ "$PLATFORM" != "mac" ]; then
    return 0
  fi

  case "$CHAT_BRIDGE" in
    kimaki) _update_kimaki_launchd ;;
  esac
}

_plist_string_after_key() {
  local plist="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "<key>" key "</key>" { found = 1; next }
    found && /<string>/ { print; exit }
  ' "$plist" | sed 's/.*<string>\(.*\)<\/string>.*/\1/'
}

_update_kimaki_launchd() {
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
  new_plist=$(bridge_render_launchd kimaki com.wp.kimaki)

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

_ensure_systemd_path_contains() {
  local current_env="$1" required_dir="$2"
  if ! echo "$current_env" | grep -q '^Environment=PATH='; then
    echo "$current_env"
    return 0
  fi
  if echo "$current_env" | grep '^Environment=PATH=' | grep -F -q "$required_dir"; then
    echo "$current_env"
    return 0
  fi

  awk -v dir="$required_dir" '
    /^Environment=PATH=/ && ! done {
      sub(/^Environment=PATH=/, "Environment=PATH=" dir ":")
      done = 1
    }
    { print }
  ' <<< "$current_env"
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
  local KIMAKI_BIN_DIR
  KIMAKI_BIN_DIR=$(dirname "$KIMAKI_BIN")
  CURRENT_ENV=$(_ensure_systemd_path_contains "$CURRENT_ENV" "$KIMAKI_BIN_DIR")

  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=$KIMAKI_BIN_DIR:/usr/local/bin:/usr/bin:/bin
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
    warn "opencode.json: managed entries were added, but unexpected plugins remain."
    warn "  Re-run with: ./upgrade.sh --repair-opencode-json"
    warn "  to remove them (the backup from this run is preserved)."
  fi

  echo ""
  _print_bridge_restart_hint
  _print_verify_block
}

# Resolve the runtime environment for restart/verify output.
# Returns: local-launchd | local-manual | vps
_resolve_bridge_env() {
  local bridge="$1" label
  if [ "$LOCAL_MODE" != true ]; then
    echo "vps"
    return
  fi
  for label in $(bridge_launchd_labels "$bridge"); do
    if [ -f "$HOME/Library/LaunchAgents/${label}.plist" ]; then
      echo "local-launchd"
      return
    fi
  done
  echo "local-manual"
}

# Print the correct restart command for the detected chat bridge × environment.
_print_bridge_restart_hint() {
  [ -n "$CHAT_BRIDGE" ] || return 0

  local env display cmd
  env=$(_resolve_bridge_env "$CHAT_BRIDGE")
  display=$(bridge_display_name "$CHAT_BRIDGE")

  warn "Restart $display when ready (active chat sessions will die):"
  while IFS= read -r cmd; do
    warn "  $cmd"
  done < <(bridge_restart_cmd "$CHAT_BRIDGE" "$env")
  echo ""
}

_print_verify_block() {
  log "Verify:"

  if [ -z "$CHAT_BRIDGE" ]; then
    log "  (no chat bridge detected)"
  else
    local env primary cmd
    env=$(_resolve_bridge_env "$CHAT_BRIDGE")
    primary=$(bridge_binaries "$CHAT_BRIDGE" | awk '{print $1}')

    while IFS= read -r cmd; do
      log "  $cmd   # chat bridge status"
    done < <(bridge_verify_cmd "$CHAT_BRIDGE" "$env")

    case "$CHAT_BRIDGE" in
      kimaki)
        local PLUGINS_DIR="${RESOLVED_KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"
        log "  ls $PLUGINS_DIR   # plugin versions"
        ;;
      *)
        log "  $primary --version   # binary version"
        ;;
    esac
  fi

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
update_chat_bridge_launchd
reapply_claude_auth_patch
print_summary
