#!/bin/bash
#
# wp-coding-agents upgrade script
# Safely upgrade a live wp-coding-agents install without touching user state.
#
# Phases:
#   1. Detect environment (auto-detects local vs VPS, runtime, chat bridge —
#      supports kimaki, cc-connect, telegram).
#   2. Update setup-installed Data Machine plugins to latest tagged releases.
#   3. Sync chat-bridge config (dispatches per bridge)
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
#   4. Sync agent skills (WordPress + Data Machine)
#   5. Regenerate AGENTS.md via Data Machine compose
#   6. Smart systemd update (VPS only; dispatches per bridge)
#        kimaki     → kimaki.service
#        cc-connect → cc-connect.service
#        telegram   → opencode-serve.service + opencode-telegram.service
#      Each unit's existing Environment= lines are preserved (host custom
#      values, secrets) while structural lines are refreshed from the same
#      template the install path uses (bridges/<name>.sh::bridge_render_*).
#   7. Re-apply opencode-claude-auth PascalCase patch (opencode runtime only)
#   8. Summary — prints the right restart + verify commands per bridge × env.
#
# Usage:
#   ./upgrade.sh                 # run all phases (auto-detects environment)
#   ./upgrade.sh --dry-run       # preview without changes
#   ./upgrade.sh --kimaki-only   # only sync kimaki config + plugins
#   ./upgrade.sh --plugins-only  # only update Data Machine plugins
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
# wordpress is needed for wp_cmd helper used by compose and plugin updates).
for lib in common detect wordpress data-machine skills; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

# Bridge dispatcher — auto-discovers bridges/*.sh. Each bridge owns its own
# render templates, sync, systemd/launchd update, and summary blocks.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"

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
PLUGINS_ONLY=false
SKILLS_ONLY=false
AGENTS_MD_ONLY=false
REPAIR_OPENCODE_JSON=false
SKIP_PLUGINS=false
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
DETECTED_RUNTIMES=()
IS_STUDIO=false
CHAT_BRIDGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)       DRY_RUN=true; shift ;;
    --kimaki-only)   KIMAKI_ONLY=true; shift ;;
    --plugins-only)  PLUGINS_ONLY=true; shift ;;
    --skills-only)   SKILLS_ONLY=true; shift ;;
    --agents-md-only) AGENTS_MD_ONLY=true; shift ;;
    --repair-opencode-json) REPAIR_OPENCODE_JSON=true; shift ;;
    --skip-plugins)  SKIP_PLUGINS=true; shift ;;
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
  ./upgrade.sh --plugins-only   Only update setup-installed Data Machine plugins
  ./upgrade.sh --skills-only    Only sync agent skills
  ./upgrade.sh --agents-md-only Only regenerate AGENTS.md
  ./upgrade.sh --skip-plugins   Skip Data Machine plugin updates during full run
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
  - data-machine and data-machine-code — updates setup-installed git
    checkouts to their latest version tags. Non-git plugin directories are
    skipped. Use --skip-plugins to skip this phase.
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

if [ "$PLUGINS_ONLY" = true ] && [ "$SKIP_PLUGINS" = true ]; then
  error "Cannot combine --plugins-only and --skip-plugins"
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
# bridges/_dispatch.sh registry walk. See bridge_detect_local /
# bridge_detect_vps for the full probe order (launchd plists + command -v
# on local; systemd unit files on VPS). Priority order is set by
# BRIDGE_DETECTION_ORDER in _dispatch.sh: kimaki > cc-connect > telegram.
if [ "$LOCAL_MODE" = true ]; then
  CHAT_BRIDGE=$(bridge_detect_local)
else
  CHAT_BRIDGE=$(bridge_detect_vps)
fi

# Load the active bridge's hooks (render, sync, update, summary) into this
# shell so the rest of upgrade.sh can call bridge_sync_config /
# bridge_update_systemd / bridge_render_systemd directly. No-op when
# detection found nothing — phase functions guard on $CHAT_BRIDGE.
if [ -n "$CHAT_BRIDGE" ] && bridge_file "$CHAT_BRIDGE" >/dev/null 2>&1; then
  bridge_load "$CHAT_BRIDGE"
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
  if [ "$KIMAKI_ONLY" = true ] || [ "$PLUGINS_ONLY" = true ] || [ "$SKILLS_ONLY" = true ] || [ "$AGENTS_MD_ONLY" = true ]; then
    case "$phase" in
      kimaki)    [ "$KIMAKI_ONLY" = true ]; return $? ;;
      plugins)   [ "$PLUGINS_ONLY" = true ]; return $? ;;
      skills)    [ "$SKILLS_ONLY" = true ]; return $? ;;
      agents-md) [ "$AGENTS_MD_ONLY" = true ]; return $? ;;
      systemd|patch) return 1 ;;  # infrastructure phases skipped in *-only modes
      *)         return 1 ;;
    esac
  fi

  if [ "$phase" = plugins ] && [ "$SKIP_PLUGINS" = true ]; then
    return 1
  fi

  return 0
}

# ============================================================================
# Phase 2: Update Data Machine plugins
# ============================================================================

update_data_machine_plugins() {
  _run_filter_active plugins || return 0
  upgrade_data_machine_plugins
}

# ============================================================================
# Phase 3: Sync chat-bridge config
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

  if [ -z "$CHAT_BRIDGE" ]; then
    log "Phase 3: Skipping (no chat bridge detected)"
    return
  fi

  if ! bridge_has_hook sync_config; then
    warn "Phase 3: $CHAT_BRIDGE does not implement bridge_sync_config — skipping"
    return
  fi

  bridge_sync_config
}


# ============================================================================
# Phase 3b: Detect + optionally repair opencode.json drift
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
  _run_filter_active opencode-json || return 0

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
    warn "Phase 3b: $HELPER not found — skipping drift check"
    return 0
  fi

  local BRIDGE_ARG="${CHAT_BRIDGE:-none}"

  # Kimaki plugins dir — match what bridges/kimaki.sh::bridge_sync_config resolved.
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

  log "Phase 3b: opencode.json $MODE_LABEL..."

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
      warn "Phase 3b: opencode.json has drift — $repair_out"
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
# Phase 4: Sync agent skills (WordPress + Data Machine)
# ============================================================================

sync_skills() {
  _run_filter_active skills || return 0

  log "Phase 4: Syncing agent skills..."

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
# Phase 5: Regenerate AGENTS.md
# ============================================================================

regenerate_agents_md() {
  _run_filter_active agents-md || return 0

  log "Phase 5: Regenerating AGENTS.md..."

  local AGENTS_MD="$SITE_PATH/AGENTS.md"
  local BACKUP="$SITE_PATH/AGENTS.md.backup.$TIMESTAMP"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would backup $AGENTS_MD → $BACKUP"
    echo -e "${BLUE}[dry-run]${NC} Would run: $WP_CMD datamachine memory compose AGENTS.md $WP_ROOT_FLAG"
    return 0
  fi

  sync_homeboy_availability

  # Backup existing (compose writes in-place to the registered location)
  if [ -f "$AGENTS_MD" ]; then
    cp "$AGENTS_MD" "$BACKUP"
    log "  Backup: $BACKUP"
  fi

  # `datamachine memory compose AGENTS.md` writes in-place to the registered
  # composable file path. It does NOT accept an arbitrary output path —
  # the filename must be a registered MemoryFileRegistry entry.
  if (cd "$SITE_PATH" && $WP_CMD datamachine memory compose AGENTS.md $WP_ROOT_FLAG >/dev/null 2>&1); then
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
    warn "  datamachine memory compose failed — AGENTS.md unchanged"
    # Restore from backup if compose wrote a partial file
    if [ -f "$BACKUP" ] && [ -f "$AGENTS_MD" ] && ! cmp -s "$BACKUP" "$AGENTS_MD"; then
      cp "$BACKUP" "$AGENTS_MD"
      warn "  Restored AGENTS.md from backup"
    fi
  fi
}

# ============================================================================
# Phase 6: Smart systemd update (merges host-specific Environment= lines)
#   Dispatches to the active bridge's bridge_update_systemd hook (and
#   bridge_update_launchd on macOS). Each bridge regenerates its unit file(s)
#   from the same template the install path uses, preserves existing
#   Environment= lines via _merge_systemd_env_lines (defined in
#   bridges/_dispatch.sh), writes + daemon-reloads, NEVER restarts.
# ============================================================================

update_chat_bridge_systemd() {
  _run_filter_active systemd || return 0

  if [ "$LOCAL_MODE" = true ]; then
    log "Phase 6: Skipping (local mode — no systemd)"
    return 0
  fi

  if [ -z "$CHAT_BRIDGE" ]; then
    log "Phase 6: Skipping (no chat bridge detected)"
    return 0
  fi

  if ! bridge_has_hook update_systemd; then
    warn "Phase 6: $CHAT_BRIDGE does not implement bridge_update_systemd — skipping"
    return 0
  fi

  bridge_update_systemd
}

update_chat_bridge_launchd() {
  if [ "$LOCAL_MODE" != true ] || [ "$PLATFORM" != "mac" ]; then
    return 0
  fi

  if [ -z "$CHAT_BRIDGE" ] || ! bridge_has_hook update_launchd; then
    return 0
  fi

  bridge_update_launchd
}

# ============================================================================
# Phase 7: Re-apply opencode-claude-auth PascalCase patch
# ============================================================================

reapply_claude_auth_patch() {
  _run_filter_active patch || return 0

  if [ "$RUNTIME" != "opencode" ]; then
    log "Phase 7: Skipping (runtime is $RUNTIME, not opencode)"
    return 0
  fi

  log "Phase 7: Re-applying opencode-claude-auth PascalCase patch..."

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
# Phase 8: Summary
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
#
# Reads bridge_launchd_labels from the active loaded bridge (no argument).
_resolve_bridge_env() {
  local label
  if [ "$LOCAL_MODE" != true ]; then
    echo "vps"
    return
  fi
  for label in $(bridge_launchd_labels); do
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
  env=$(_resolve_bridge_env)
  display=$(bridge_display_name)

  warn "Restart $display when ready (active chat sessions will die):"
  while IFS= read -r cmd; do
    warn "  $cmd"
  done < <(bridge_restart_cmd "$env")
  echo ""
}

_print_verify_block() {
  log "Verify:"

  if [ -z "$CHAT_BRIDGE" ]; then
    log "  (no chat bridge detected)"
  else
    local env cmd
    env=$(_resolve_bridge_env)

    while IFS= read -r cmd; do
      log "  $cmd   # chat bridge status"
    done < <(bridge_verify_cmd "$env")

    # Optional per-bridge addendum (e.g. kimaki's `ls plugins/` line). Falls
    # back to `<binary> --version` for bridges that don't define the hook.
    if bridge_has_hook verify_extra; then
      while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        log "  $cmd"
      done < <(bridge_verify_extra)
    else
      local primary
      primary=$(bridge_binaries | awk '{print $1}')
      log "  $primary --version   # binary version"
    fi
  fi

  log "  $WP_CMD plugin get data-machine --field=version --path=$SITE_PATH $WP_ROOT_FLAG"
  log "  $WP_CMD plugin get data-machine-code --field=version --path=$SITE_PATH $WP_ROOT_FLAG"
  log "  cat $SITE_PATH/AGENTS.md | head -20   # agent instructions"
  log "  ls $(runtime_skills_dir)              # installed skills"
}

# ============================================================================
# Execute
# ============================================================================

update_data_machine_plugins
sync_chat_bridge_config
check_opencode_json_drift
sync_skills
regenerate_agents_md
update_chat_bridge_systemd
update_chat_bridge_launchd
reapply_claude_auth_patch
print_summary
