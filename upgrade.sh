#!/bin/bash
#
# wp-coding-agents upgrade script
# Safely upgrade a live wp-coding-agents install without touching user state.
#
# Phases:
#   1. Detect environment (auto-detects local vs VPS, runtime, chat bridge —
#      supports kimaki, cc-connect, telegram).
#   2. Update setup-installed Data Machine plugins to latest tagged releases,
#      sync carried provider plugins, and sync WP Codebox (subtree-packaged)
#      to its latest tag when installed.
#   3. Sync chat-bridge config (dispatches per bridge)
#        kimaki:
#          VPS:   /opt/kimaki-config (plugins + post-upgrade.sh + skill allowlist)
#          Local: $KIMAKI_DATA_DIR/kimaki-config/ for plugins,
#                 post-upgrade.sh + skill allowlist, and runs post-upgrade.sh inline (no launchd
#                 ExecStartPre hook).
#        cc-connect: no per-install artifacts; reports binary version and
#          reminds user to `npm update -g cc-connect`.
#        telegram: no per-install artifacts; reports binary versions and
#          reminds user to `npm update -g @grinev/opencode-telegram-bot`.
#   4. Sync the wp-coding-agents upgrade skill
#   5. Regenerate AGENTS.md via Data Machine compose
#   6. Smart systemd update (VPS only; dispatches per bridge)
#        kimaki     → kimaki.service
#        cc-connect → cc-connect.service
#        telegram   → opencode-serve.service + opencode-telegram.service
#      Each unit's existing Environment= lines are preserved (host custom
#      values, secrets) while structural lines are refreshed from the same
#      template the install path uses (bridges/<name>.sh::bridge_render_*).
#   7. Remove legacy opencode-claude-auth bash wrapper, if any (#117)
#   8. Summary — prints the right restart + verify commands per bridge × env.
#
# Usage:
#   ./upgrade.sh                 # run all phases (auto-detects environment)
#   ./upgrade.sh --dry-run       # preview without changes
#   ./upgrade.sh --kimaki-only   # only sync kimaki config + plugins
#   ./upgrade.sh --plugins-only  # only update Data Machine plugins
#   ./upgrade.sh --skills-only   # only sync the wp-coding-agents upgrade skill
#   ./upgrade.sh --agents-md-only  # only regenerate AGENTS.md
#   ./upgrade.sh --local --wp-path <path>  # local install (auto on macOS)
#
# Safety: NEVER touches WordPress DB, nginx, SSL, ~/.kimaki/ auth state,
#   the DM workspace cloned repos, agent memory files, or the running
#   chat-bridge service.
#
#   opencode.json is touched by default in additive mode: managed plugin
#   entries the user is missing get added (dm-context-filter.ts and
#   dm-agent-sync.ts on Kimaki bridges), and legacy
#   `agent.build.prompt`/`agent.plan.prompt` keys get migrated to a top-level
#   `instructions` array (fixes Anthropic Claude Max OAuth, see
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
for lib in common detect wordpress data-machine carried-plugins wp-codebox homeboy ai-gateway skills cli-transport cli-channel runtime-signature agents-md-guidance agents-md-backups; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

# Bridge dispatcher — auto-discovers bridges/*.sh. Each bridge owns its own
# render templates, sync, systemd/launchd update, and summary blocks.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/services/datamachine-worker.sh"

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
WITH_AI_GATEWAY=false
WITH_CLAUDE_CODE_AUTH=true
ROTATE_AI_GATEWAY_TOKEN=false
SHOW_HELP=false

# Defaults setup.sh expects (detect.sh reads these)
LOCAL_MODE=false
SKIP_DEPS=true
SKIP_SSL=true
INSTALL_DATA_MACHINE=true
INSTALL_CHAT=true
INSTALL_SKILLS=true
RUN_AS_ROOT=true
REQUIRE_ROOT_DURING_DETECT=false
MULTISITE=false
MULTISITE_TYPE="subdirectory"
MODE="existing"
RUNTIME=""
DETECTED_RUNTIMES=()
IS_STUDIO=false
CHAT_BRIDGE=""
HOMEBOY_MODE="${HOMEBOY_MODE:-auto}"
WITH_HOMEBOY="${WITH_HOMEBOY:-false}"
# True when the operator forced the identity via --root / --non-root.
# Suppresses adopt_service_identity_from_units (existing-unit adoption).
SERVICE_USER_FORCED=false
initialize_kimaki_overrides

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)       DRY_RUN=true; shift ;;
    --kimaki-only)   KIMAKI_ONLY=true; shift ;;
    --plugins-only)  PLUGINS_ONLY=true; shift ;;
    --skills-only)   SKILLS_ONLY=true; shift ;;
    --agents-md-only) AGENTS_MD_ONLY=true; shift ;;
    --repair-opencode-json) REPAIR_OPENCODE_JSON=true; shift ;;
    --skip-plugins)  SKIP_PLUGINS=true; shift ;;
    --with-ai-gateway) WITH_AI_GATEWAY=true; shift ;;
    --with-claude-code-auth) WITH_CLAUDE_CODE_AUTH=true; shift ;;
    --no-claude-code-auth) WITH_CLAUDE_CODE_AUTH=false; shift ;;
    --ai-gateway-provider) AI_GATEWAY_ROUTE_PROVIDER="$2"; shift 2 ;;
    --ai-gateway-model) AI_GATEWAY_ROUTE_MODEL="$2"; shift 2 ;;
    --ai-gateway-opencode-model) AI_GATEWAY_MODEL_ID="$2"; shift 2 ;;
    --rotate-ai-gateway-token) ROTATE_AI_GATEWAY_TOKEN=true; shift ;;
    --runtime)       RUNTIME="$2"; shift 2 ;;
    --wp-path)       EXISTING_WP="$2"; shift 2 ;;
    --agent-slug)    AGENT_SLUG="$2"; AGENT_SLUG_EXPLICIT=true; shift 2 ;;
    --kimaki-unit)   KIMAKI_UNIT="$2"; KIMAKI_UNIT_EXPLICIT=true; shift 2 ;;
    --kimaki-data-dir) KIMAKI_DATA_DIR="$2"; KIMAKI_DATA_DIR_EXPLICIT=true; shift 2 ;;
    --kimaki-lock-port) KIMAKI_LOCK_PORT="$2"; KIMAKI_LOCK_PORT_EXPLICIT=true; shift 2 ;;
    --local)         LOCAL_MODE=true; RUN_AS_ROOT=false; shift ;;
    --root)          RUN_AS_ROOT=true;  SERVICE_USER_FORCED=true; shift ;;
    --non-root)      RUN_AS_ROOT=false; SERVICE_USER_FORCED=true; shift ;;
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
  ./upgrade.sh --skills-only    Only sync the wp-coding-agents upgrade skill
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
  ./upgrade.sh --agent-slug <s> Override Data Machine agent slug
  ./upgrade.sh --kimaki-unit <u> Target Kimaki systemd unit
  ./upgrade.sh --kimaki-data-dir <path>
                                 Override the selected Kimaki state directory
  ./upgrade.sh --kimaki-lock-port <port>
                                 Override the selected Kimaki lock port
  ./upgrade.sh --local          Local mode (no systemd; auto-on on macOS)
  ./upgrade.sh --root           Force root service identity (skips adoption
                                of the existing unit's User=)
  ./upgrade.sh --non-root       Force non-root service identity (User=opencode)
  ./upgrade.sh --with-ai-gateway
                                Opt in to additive WP AI Gateway integration
                                for OpenCode: install/activate gateway stack,
                                configure route, reuse existing token env, and
                                merge a wp-ai-gateway OpenAI-compatible provider
                                into opencode.json.
  ./upgrade.sh --with-ai-gateway --rotate-ai-gateway-token
                                Explicitly mint a replacement gateway token.
  ./upgrade.sh --with-ai-gateway --ai-gateway-provider openai --ai-gateway-model gpt-4o-mini
                                Configure the WordPress gateway backend route.
  ./upgrade.sh --no-claude-code-auth
                                Skip direct OpenCode Claude Pro/Max auth.
                                The managed auth plugin is installed by default
                                for OpenCode runtimes.

SERVICE IDENTITY:
  By default the upgrade adopts the service user from the EXISTING
  installed systemd unit (its User= line) rather than assuming root.
  The upgrade never changes the service identity implicitly; use
  --root / --non-root to change it deliberately.

SUPPORTED CHAT BRIDGES:
  kimaki, cc-connect, telegram  (auto-detected per environment)

KIMAKI PLUGIN INSTALL TARGETS:
  VPS:   /opt/kimaki-config/plugins
  Local: \$KIMAKI_DATA_DIR/kimaki-config/plugins

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
    skipped. Carried provider plugins are synced from this repo when their
    runtime is present. Use --skip-plugins to skip this phase.
  - opencode.json — additive repair. Adds managed plugin entries the
    user is missing (dm-context-filter.ts and dm-agent-sync.ts on Kimaki
    bridges) and migrates "agent.build.prompt" to top-level "instructions"
    (fixes Anthropic Claude Max OAuth). Never removes user-added plugins.
    Preserves all other keys. Writes a .backup.<ts> alongside.
  - AGENTS.md.backup.* — prunes old generated backups after successful
    AGENTS.md regeneration. Defaults: keep latest 5 and remove older extras
    after 30 days. Override with AGENTS_MD_BACKUP_KEEP and
    AGENTS_MD_BACKUP_MAX_AGE_DAYS.

OPT-IN TOUCHES:
  - opencode.json (--repair-opencode-json) — full reconcile. In addition
    to the additive behaviour above, removes unexpected plugin entries
    so the array matches exactly what setup would produce today.
  - WP AI Gateway (--with-ai-gateway) — installs/updates wp-ai-gateway and
    ai-provider-for-openai, configures the gateway route, writes/reuses
    .opencode/wp-ai-gateway.env, and additively merges provider.wp-ai-gateway
    into opencode.json. Existing gateway tokens are reused unless
    --rotate-ai-gateway-token is also passed.
  - OpenCode Claude Code auth — installs a managed OpenCode plugin under
    .opencode/plugins and adds it to opencode.json so direct OpenCode can
    authenticate with Claude Pro/Max OAuth. Use --no-claude-code-auth to skip.
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

  # A host may serve several sites. Selecting the first glob result is unsafe.
  wp_candidates=()
  for candidate in /var/www/*/; do
    if [ -f "$candidate/wp-config.php" ]; then
      wp_candidates+=("${candidate%/}")
    fi
  done

  if [ ${#wp_candidates[@]} -eq 1 ]; then
    EXISTING_WP="${wp_candidates[0]}"
    log "Auto-detected WordPress at: $EXISTING_WP"
  elif [ ${#wp_candidates[@]} -gt 1 ]; then
    error "Multiple WordPress installs found under /var/www. Pass --wp-path <path>: ${wp_candidates[*]}"
  fi

  if [ -z "$EXISTING_WP" ]; then
    error "Could not auto-detect WordPress path. Pass --wp-path <path> or set EXISTING_WP."
  fi
fi

# Auto-detect runtime(s). Same model as setup.sh: DETECTED_RUNTIMES is the
# full list (drives multi-runtime skills install); RUNTIME is the primary
# (first-match cascade: claude-code > opencode > codex). Explicit --runtime
# narrows to a single runtime.
if [ -n "$RUNTIME" ]; then
  DETECTED_RUNTIMES=("$RUNTIME")
else
  if command -v claude &>/dev/null; then
    DETECTED_RUNTIMES+=("claude-code")
  fi
  if command -v opencode &>/dev/null; then
    DETECTED_RUNTIMES+=("opencode")
  fi
  if command -v codex &>/dev/null; then
    DETECTED_RUNTIMES+=("codex")
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
#
# Codex has no managed bridge in wp-coding-agents today. An explicit
# `--runtime codex` upgrade should sync Codex-owned files only, not pick up an
# unrelated local Kimaki/cc-connect install and rewrite its config.
if [ "$RUNTIME" = "codex" ]; then
  CHAT_BRIDGE=""
elif [ "$LOCAL_MODE" = true ]; then
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

if [ "$CHAT_BRIDGE" = "kimaki" ] && [ "$LOCAL_MODE" = false ]; then
  _kimaki_resolve_instance
fi

# On upgrade, the installed unit's User= is the source of truth for the
# service identity. upgrade.sh defaults RUN_AS_ROOT=true, which on a
# non-root install (User=opencode) made Phase 5 silently rewrite the unit
# to User=root — root-owned state files, broken next non-root start, and
# the root-homed-path dispatch trap (#198/#93) all over again. See #204.
# --root / --non-root force an explicit identity and skip adoption.
adopt_service_identity_from_units

if [ "$DRY_RUN" = false ] && [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = true ] && [ "$EUID" -ne 0 ]; then
  error "Please run as root (sudo ./upgrade.sh), or use --non-root for installs whose service and WordPress files are writable by the current user."
fi

log "Runtime:     $RUNTIME"
log "Chat bridge: ${CHAT_BRIDGE:-none detected}"
log "Site path:   $SITE_PATH"
log "Service:     $SERVICE_USER"
if [ "$CHAT_BRIDGE" = "kimaki" ]; then
  log "Kimaki unit: $KIMAKI_UNIT"
  log "Kimaki data: $KIMAKI_DATA_DIR"
  [ -z "$KIMAKI_LOCK_PORT" ] || log "Kimaki lock: $KIMAKI_LOCK_PORT"
fi
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
      opencode-json) [ "$KIMAKI_ONLY" = true ]; return $? ;;
      plugins)   [ "$PLUGINS_ONLY" = true ]; return $? ;;
      skills)    [ "$SKILLS_ONLY" = true ]; return $? ;;
      agents-md) [ "$AGENTS_MD_ONLY" = true ]; return $? ;;
      transport|systemd|patch) return 1 ;;  # infrastructure phases skipped in *-only modes
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
  sync_carried_plugins
  update_wp_codebox_plugin_subtree
}

configure_homeboy_dmc_worktree_provider_phase() {
  _run_filter_active plugins || return 0
  configure_homeboy_dmc_worktree_provider
}

sync_cli_transport_runtime() {
  _run_filter_active transport || return 0

  log "Phase 2b: Syncing CLI dispatch transport..."
  cli_transport_install
}

update_ai_gateway() {
  _run_filter_active plugins || return 0
  upgrade_ai_gateway
}

# ============================================================================
# Phase 3: Sync chat-bridge config
#   kimaki    → plugins + post-upgrade.sh + skills-enable-list (see below).
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

upgrade_opencode_claude_code_auth_plugin_path() {
  printf '%s/.opencode/plugins/claude-code-auth.ts' "$SITE_PATH"
}

upgrade_install_opencode_claude_code_auth_plugin() {
  [ "${WITH_CLAUDE_CODE_AUTH:-false}" = true ] || return 0

  local plugin_path plugins_dir source_path
  plugin_path="$(upgrade_opencode_claude_code_auth_plugin_path)"
  plugins_dir="$(dirname "$plugin_path")"
  source_path="$SCRIPT_DIR/runtimes/opencode/plugins/claude-code-auth.ts"

  if [ ! -f "$source_path" ]; then
    warn "Phase 3b: $source_path not found — skipping Claude Code auth OpenCode plugin sync"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install Claude Code auth OpenCode plugin at $plugin_path"
    return 0
  fi

  mkdir -p "$plugins_dir"
  if [ -f "$plugin_path" ] && cmp -s "$source_path" "$plugin_path"; then
    return 0
  fi

  cp "$source_path" "$plugin_path"
  service_file_normalize_perms "$plugin_path"
  UPDATED_ITEMS+=("OpenCode Claude Code auth plugin ($plugin_path)")
}

check_opencode_json_drift() {
  _run_filter_active opencode-json || return 0

  # Runs whenever opencode.json exists on disk. Default behaviour is
  # additive repair: managed plugin entries the user is missing get added
  # (dm-context-filter.ts and dm-agent-sync.ts on Kimaki bridges), and
  # legacy agent.build.prompt / agent.plan.prompt get migrated to a
  # top-level `instructions` array (fixes Anthropic Claude Max OAuth,
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
  upgrade_install_opencode_claude_code_auth_plugin
  local CLAUDE_CODE_AUTH_PLUGIN=""
  local claude_code_auth_args=()
  if [ "${WITH_CLAUDE_CODE_AUTH:-false}" = true ]; then
    CLAUDE_CODE_AUTH_PLUGIN="$(upgrade_opencode_claude_code_auth_plugin_path)"
    claude_code_auth_args=(--claude-code-auth-plugin "$CLAUDE_CODE_AUTH_PLUGIN")
  fi

  # Runtime arg for repair-opencode-json.py: always `opencode` when the file
  # exists. The primary RUNTIME may be `claude-code`, but the presence of
  # opencode.json on disk means opencode IS in use — otherwise the file wouldn't
  # be there. expected_plugins() skips plugin-array drift entirely for
  # non-opencode runtimes, which would silently mask real drift here.
  local RUNTIME_ARG="opencode"

  local MANAGED_INSTRUCTIONS_FILE=""
  local AGENT_FOR_INSTRUCTIONS=""
  AGENT_FOR_INSTRUCTIONS=$(python3 - "$OPENCODE_JSON_FILE" <<'PY' 2>/dev/null || true
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

for item in data.get("instructions", []):
    if not isinstance(item, str):
        continue
    match = re.search(r"(?:^|/)agents/([^/]+)/", item)
    if match:
        print(match.group(1))
        break
PY
)
  if [ -n "$AGENT_FOR_INSTRUCTIONS" ]; then
    local injectable_raw injectable_json
    injectable_raw=$($WP_CMD datamachine memory injectable-files --format=json --agent="$AGENT_FOR_INSTRUCTIONS" --path="$SITE_PATH" $WP_ROOT_FLAG 2>/dev/null || echo "")
    injectable_json=$(echo "$injectable_raw" | sed -n '/^\[/,/^\]/p')
    if [ -n "$injectable_json" ]; then
      MANAGED_INSTRUCTIONS_FILE=$(mktemp)
      echo "$injectable_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    path = item.get('path')
    if path:
        print(path)
" > "$MANAGED_INSTRUCTIONS_FILE"
    fi
  fi

  # Mode: --apply (full reconcile, opt-in) or --additive (default).
  local MODE_FLAG="--additive"
  local MODE_LABEL="additive repair"
  if [ "$REPAIR_OPENCODE_JSON" = true ]; then
    MODE_FLAG="--apply"
    MODE_LABEL="full repair"
  fi

  log "Phase 3b: opencode.json $MODE_LABEL..."

  if [ "$DRY_RUN" = true ]; then
    local managed_arg_display=""
    if [ -n "$MANAGED_INSTRUCTIONS_FILE" ]; then
      managed_arg_display=" --managed-instructions-file $MANAGED_INSTRUCTIONS_FILE"
    fi
    local claude_auth_arg_display=""
    if [ -n "$CLAUDE_CODE_AUTH_PLUGIN" ]; then
      claude_auth_arg_display=" --claude-code-auth-plugin $CLAUDE_CODE_AUTH_PLUGIN"
    fi
    echo -e "${BLUE}[dry-run]${NC} Would run: python3 $HELPER --file $OPENCODE_JSON_FILE --runtime $RUNTIME_ARG --chat-bridge $BRIDGE_ARG --kimaki-plugins-dir $PLUGINS_DIR$claude_auth_arg_display$managed_arg_display $MODE_FLAG"
    local dry_out
    local managed_args=()
    if [ -n "$MANAGED_INSTRUCTIONS_FILE" ]; then
      managed_args=(--managed-instructions-file "$MANAGED_INSTRUCTIONS_FILE")
    fi
    dry_out=$(python3 "$HELPER" \
      --file "$OPENCODE_JSON_FILE" \
      --runtime "$RUNTIME_ARG" \
      --chat-bridge "$BRIDGE_ARG" \
      --kimaki-plugins-dir "$PLUGINS_DIR" \
      "${claude_code_auth_args[@]}" \
      "${managed_args[@]}" 2>&1 || true)
    echo "$dry_out" | sed 's/^/    /'
    [ -z "$MANAGED_INSTRUCTIONS_FILE" ] || rm -f "$MANAGED_INSTRUCTIONS_FILE"
    return 0
  fi

  local repair_out repair_rc
  local managed_args=()
  if [ -n "$MANAGED_INSTRUCTIONS_FILE" ]; then
    managed_args=(--managed-instructions-file "$MANAGED_INSTRUCTIONS_FILE")
  fi
  repair_out=$(python3 "$HELPER" \
    --file "$OPENCODE_JSON_FILE" \
    --runtime "$RUNTIME_ARG" \
    --chat-bridge "$BRIDGE_ARG" \
    --kimaki-plugins-dir "$PLUGINS_DIR" \
    "${claude_code_auth_args[@]}" \
    "${managed_args[@]}" \
    "$MODE_FLAG" \
    --backup-suffix "$TIMESTAMP" 2>&1) && repair_rc=0 || repair_rc=$?
  [ -z "$MANAGED_INSTRUCTIONS_FILE" ] || rm -f "$MANAGED_INSTRUCTIONS_FILE"

  # repair-opencode-json.py writes both the target file and its own backup
  # via plain Python open() — inherits the caller's umask/identity same as
  # every other service-file writer in this repo. Normalize both.
  service_file_normalize_perms "$OPENCODE_JSON_FILE"
  service_file_normalize_perms "${OPENCODE_JSON_FILE}.backup.$TIMESTAMP"

  local repair_status prompt_migration instruction_sync
  repair_status=$(echo "$repair_out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('status','?'))" 2>/dev/null || echo "parse-error")
  prompt_migration=$(echo "$repair_out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('prompt_migration','?'))" 2>/dev/null || echo "?")
  instruction_sync=$(echo "$repair_out" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('instruction_sync','?'))" 2>/dev/null || echo "?")

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
      if [ "$instruction_sync" = "synced" ]; then
        UPDATED_ITEMS+=("opencode.json Data Machine instructions")
      fi
      if echo "$repair_out" | grep -q '"added": \["'; then
        UPDATED_ITEMS+=("opencode.json plugin array (added missing managed entries)")
      fi
      ;;
    needs_full_repair)
      warn "  opencode.json additively repaired, but unexpected plugin entries remain"
      warn "  Run './upgrade.sh --repair-opencode-json' to remove them (backup: ${OPENCODE_JSON_FILE}.backup.$TIMESTAMP)"
      warn "  $repair_out"
      if [ "$prompt_migration" = "migrated" ]; then
        UPDATED_ITEMS+=("opencode.json prompt → instructions migration")
      fi
      if [ "$instruction_sync" = "synced" ]; then
        UPDATED_ITEMS+=("opencode.json Data Machine instructions")
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
      if [ "$instruction_sync" = "synced" ]; then
        UPDATED_ITEMS+=("opencode.json Data Machine instructions")
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
# Phase 4: Sync wp-coding-agents upgrade skill
# ============================================================================

sync_skills() {
  _run_filter_active skills || return 0

  log "Phase 4: Syncing wp-coding-agents upgrade skill..."

  if [ "$DRY_RUN" = true ]; then
    SKILLS_DIR="$(runtime_skills_dir)"
    echo -e "${BLUE}[dry-run]${NC} Would install upgrade skill from $SCRIPT_DIR/skills → $SKILLS_DIR"
    if [ "$CHAT_BRIDGE" = "kimaki" ]; then
      echo -e "${BLUE}[dry-run]${NC} Would copy upgrade skill to kimaki skills dir"
    fi
    return 0
  fi

  install_skills
  UPDATED_ITEMS+=("wp-coding-agents upgrade skill")
}

# ============================================================================
# Phase 5: Regenerate AGENTS.md
# ============================================================================

regenerate_agents_md() {
  _run_filter_active agents-md || return 0

  log "Phase 5: Regenerating AGENTS.md..."

  local AGENTS_MD="$SITE_PATH/AGENTS.md"
  local BACKUP="$SITE_PATH/AGENTS.md.backup.$TIMESTAMP"
  local CLAUDE_MD="$SITE_PATH/CLAUDE.md"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would backup $AGENTS_MD → $BACKUP"
    echo -e "${BLUE}[dry-run]${NC} Would sync Homeboy AGENTS.md CLI guidance mu-plugin"
    echo -e "${BLUE}[dry-run]${NC} Would run: $WP_CMD datamachine memory compose AGENTS.md $WP_ROOT_FLAG"
    if _runtime_detected opencode; then
      echo -e "${BLUE}[dry-run]${NC} Would symlink $CLAUDE_MD → AGENTS.md (Claude-model context)"
    fi
    return 0
  fi

  sync_homeboy_availability
  sync_homeboy_agents_md_guidance

  # Backup existing (compose writes in-place to the registered location)
  if [ -f "$AGENTS_MD" ]; then
    cp "$AGENTS_MD" "$BACKUP"
    service_file_normalize_perms "$BACKUP"
    log "  Backup: $BACKUP"
  fi

  # `datamachine memory compose AGENTS.md` writes in-place to the registered
  # composable file path. It does NOT accept an arbitrary output path —
  # the filename must be a registered MemoryFileRegistry entry. Compose runs
  # as the wp-coding-agents caller's identity (root during upgrade, opencode
  # during local dev), so normalize afterward the same way every other
  # service-file writer does — otherwise the identity that ran this upgrade
  # is the only one that can write AGENTS.md until the next normalize.
  if (cd "$SITE_PATH" && $WP_CMD datamachine memory compose AGENTS.md $WP_ROOT_FLAG >/dev/null 2>&1); then
    service_file_normalize_perms "$AGENTS_MD"
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
    agents_md_prune_backups "$SITE_PATH"
  else
    warn "  datamachine memory compose failed — AGENTS.md unchanged"
    # Restore from backup if compose wrote a partial file
    if [ -f "$BACKUP" ] && [ -f "$AGENTS_MD" ] && ! cmp -s "$BACKUP" "$AGENTS_MD"; then
      cp "$BACKUP" "$AGENTS_MD"
      service_file_normalize_perms "$AGENTS_MD"
      warn "  Restored AGENTS.md from backup"
    fi
  fi

  # Symlink CLAUDE.md → AGENTS.md so Claude-model OpenCode sessions get the same DM context.
  # OpenCode reads both filenames from the cwd glob (AGENTS.md, CLAUDE.md, CONTEXT.md),
  # Claude Code reads only CLAUDE.md. Symlink keeps both runtimes covered without
  # duplicating content or risking drift on AGENTS.md regeneration. Relative target
  # ensures the symlink survives directory moves.
  # See: Extra-Chill/wp-coding-agents#108
  if [ -f "$AGENTS_MD" ] && _runtime_detected opencode; then
    # Skip if CLAUDE.md exists as a regular file (e.g. claude-code runtime
    # generates its own CLAUDE.md from a template — don't clobber it).
    if [ -L "$CLAUDE_MD" ] || [ ! -e "$CLAUDE_MD" ]; then
      (cd "$SITE_PATH" && ln -sf AGENTS.md CLAUDE.md)
      log "  Symlinked CLAUDE.md → AGENTS.md (covers Claude-model opencode sessions)"
    else
      log "  CLAUDE.md exists as a regular file — leaving it alone (runtime-managed)"
    fi
  fi
}

_runtime_detected() {
  local candidate="$1"
  local runtime
  for runtime in "${DETECTED_RUNTIMES[@]:-}"; do
    [ "$runtime" = "$candidate" ] && return 0
  done
  [ "${RUNTIME:-}" = "$candidate" ]
}

# ============================================================================
# Phase 5b: Sync Claude Code runtime (SessionStart hook + CLAUDE.md)
#   Claude Code installs aren't covered by the chat-bridge phases: opencode.json
#   drift, kimaki plugins, and systemd units don't apply to them. Their managed
#   surface is the SessionStart hook (.claude/hooks/dm-agent-sync.sh), its
#   agent-scope sidecar, the settings.json hook registration, and the
#   template-generated CLAUDE.md. Without this phase those silently rot: a stale
#   hook keeps exit 0-ing and CLAUDE.md never gets its Data Machine memory
#   block, so the agent boots with no personality/memory. This mirrors what
#   setup.sh installs and keeps claude-code a first-class upgrade target
#   alongside opencode.
# ============================================================================

# Resolve AGENT_SLUG for the claude-code runtime sync. Leaves AGENT_SLUG empty
# when no single agent can be confidently resolved — the hook then falls back
# to discovering all active agents.
_resolve_claude_code_agent_slug() {
  # 1. Explicit override (env / --agent-slug) wins.
  [ -n "${AGENT_SLUG:-}" ] && return 0

  # 2. Existing sidecar from a prior setup/upgrade.
  local env_file="$SITE_PATH/.claude/hooks/dm-agent-sync.env"
  if [ -f "$env_file" ]; then
    AGENT_SLUG=$(sed -n 's/^DM_AGENT_SLUG=//p' "$env_file" | head -1)
    [ -n "$AGENT_SLUG" ] && return 0
  fi

  # 3. Derive candidates and validate each against the DM agent list. Only
  #    adopt a slug when an agent with that name actually exists, so we never
  #    scope the hook to a non-existent agent. Two candidates, in order:
  #      a. domain-derived (correct for VPS installs with a real siteurl)
  #      b. directory-basename-derived (correct for Studio, where siteurl is
  #         http://localhost:PORT and the agent is named after the site folder)
  #    In dry-run, surface the first non-empty candidate without hitting the DB.
  local candidate
  for candidate in \
    "$(derive_agent_slug "$SITE_DOMAIN")" \
    "$(derive_agent_slug "$(basename "$SITE_PATH")")"; do
    [ -n "$candidate" ] || continue
    if [ "$DRY_RUN" = true ]; then
      AGENT_SLUG="$candidate"
      return 0
    fi
    if _dm_agent_slug_exists "$candidate"; then
      AGENT_SLUG="$candidate"
      return 0
    fi
  done
}

# Return 0 if a Data Machine agent with the given slug exists.
_dm_agent_slug_exists() {
  local slug="$1" json
  # shellcheck disable=SC2086
  json=$($WP_CMD datamachine agents list --format=json $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null) || return 1
  echo "$json" | python3 -c "
import sys, json, re
raw = sys.stdin.read()
m = re.search(r'\[.*\]', raw, re.DOTALL)
if not m:
    sys.exit(1)
slug = sys.argv[1]
data = json.loads(m.group())
sys.exit(0 if any(a.get('agent_slug') == slug for a in data) else 1)
" "$slug" >/dev/null 2>&1
}

sync_claude_code_runtime() {
  _run_filter_active agents-md || return 0
  [ "$RUNTIME" = "claude-code" ] || return 0

  if ! declare -F runtime_install_hooks >/dev/null; then
    return 0
  fi

  log "Phase 5b: Syncing Claude Code runtime (hook + CLAUDE.md)..."

  _resolve_claude_code_agent_slug
  if [ -n "${AGENT_SLUG:-}" ]; then
    log "  Agent scope: $AGENT_SLUG (single-agent, OpenCode parity)"
  else
    log "  Agent scope: all active agents (no single agent resolved)"
  fi

  # Regenerate a degenerate CLAUDE.md. A healthy CLAUDE.md carries the
  # DM_AGENT_SYNC sentinel block; if it's missing (truncated to @AGENTS.md by an
  # older/legacy install) or the file is absent, rebuild from the template so
  # the memory block and Studio context return. Only do this when a slug is
  # resolved — regenerating with no agent would write an empty memory block.
  local claude_md="$SITE_PATH/CLAUDE.md"
  local need_regen=false
  if [ ! -f "$claude_md" ]; then
    need_regen=true
  elif ! grep -q 'DM_AGENT_SYNC_START' "$claude_md"; then
    need_regen=true
  fi

  if [ "$need_regen" = true ] && [ -n "${AGENT_SLUG:-}" ]; then
    runtime_discover_dm_paths
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would (back up and) regenerate CLAUDE.md from template"
    elif [ -f "$claude_md" ]; then
      cp "$claude_md" "$claude_md.backup.$TIMESTAMP"
      service_file_normalize_perms "$claude_md.backup.$TIMESTAMP"
      rm -f "$claude_md"
      log "  CLAUDE.md was missing the DM memory block — backed up to $claude_md.backup.$TIMESTAMP"
      UPDATED_ITEMS+=("CLAUDE.md regenerated")
    fi
    runtime_generate_config
  elif [ "$need_regen" = true ]; then
    warn "  CLAUDE.md needs regeneration but no agent slug resolved — leaving as-is"
  fi

  # Recopy the SessionStart hook, refresh the agent-scope sidecar, and ensure
  # settings.json registers the hook + workspace permissions. Idempotent.
  runtime_install_hooks
}

sync_runtime_signature() {
  _run_filter_active patch || return 0

  _runtime_detected codex || return 0

  local codex_runtime_file="$SCRIPT_DIR/runtimes/codex.sh"
  if ! declare -F _codex_register_runtime_signature >/dev/null; then
    # shellcheck disable=SC1090
    source "$codex_runtime_file"
  fi

  if declare -F _codex_register_runtime_signature >/dev/null; then
    log "Phase 5c: Syncing Codex runtime signature..."
    _codex_register_runtime_signature
  fi

  if [ "$RUNTIME" != "codex" ] && [ -n "${RUNTIME_FILE:-}" ] && [ -f "$RUNTIME_FILE" ]; then
    # shellcheck disable=SC1090
    source "$RUNTIME_FILE"
  fi
}

sync_runtime_instructions() {
  _run_filter_active agents-md || return 0

  if _runtime_detected codex; then
    local codex_runtime_file="$SCRIPT_DIR/runtimes/codex.sh"
    if [ "$RUNTIME" != "codex" ]; then
      # shellcheck disable=SC1090
      source "$codex_runtime_file"
    fi
    if declare -F runtime_sync_instructions >/dev/null; then
      log "Phase 5d: Syncing Codex runtime instructions..."
      runtime_sync_instructions
    fi
    if [ "$RUNTIME" != "codex" ] && [ -n "${RUNTIME_FILE:-}" ] && [ -f "$RUNTIME_FILE" ]; then
      # shellcheck disable=SC1090
      source "$RUNTIME_FILE"
    fi
    return 0
  fi

  if declare -F runtime_sync_instructions >/dev/null; then
    log "Phase 5d: Syncing $RUNTIME runtime instructions..."
    runtime_sync_instructions
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

  if [ "$EUID" -ne 0 ]; then
    warn "Phase 6: Skipping systemd unit refresh because upgrade is running non-root"
    warn "  Re-run as root when unit templates need refreshing; the service will not be restarted automatically."
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

update_datamachine_worker_service() {
  _run_filter_active systemd || return 0
  if [ "$LOCAL_MODE" = false ] && [ "$EUID" -ne 0 ]; then
    warn "Skipping Data Machine worker unit refresh because upgrade is running non-root"
    return 0
  fi
  datamachine_worker_update
}

# ============================================================================
# Phase 7: Remove legacy opencode-claude-auth wrapper, if any
#
# wp-coding-agents used to install a bash wrapper at the global `opencode`
# binary path that synced Kimaki's Anthropic OAuth credentials into
# ~/.claude/.credentials.json so the third-party `opencode-claude-auth`
# plugin could read them. That whole integration was retired (see #117):
# Kimaki has a built-in AnthropicAuthPlugin and non-kimaki bridges use
# opencode's native auth flow. This phase deletes any leftover wrapper
# left behind by older upgrades and restores the npm-shipped binary.
# ============================================================================

remove_legacy_opencode_wrapper_phase() {
  _run_filter_active patch || return 0

  if [ "$RUNTIME" != "opencode" ] && [ "$CHAT_BRIDGE" != "kimaki" ]; then
    log "Phase 7: Skipping (runtime is $RUNTIME and chat bridge is ${CHAT_BRIDGE:-none})"
    return 0
  fi

  log "Phase 7: Checking for legacy opencode wrapper..."

  if ! declare -F _remove_legacy_opencode_wrapper >/dev/null; then
    # Source runtime file for the helper without running a full install.
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/runtimes/opencode.sh"
  fi

  _remove_legacy_opencode_wrapper

  # Refresh the worktree runtime-signature registration so existing installs
  # pick up the opencode entry on upgrade (and any future signature drift).
  # Idempotent — only mutates the mu-plugin file when the env-var map
  # actually differs from what is already on disk.
  if declare -F _opencode_register_runtime_signature >/dev/null; then
    _opencode_register_runtime_signature
  fi

  # This phase may source runtimes/opencode.sh for helper access even when the
  # primary runtime is something else. Restore the selected runtime functions
  # so summary/verification paths still come from the active runtime.
  if [ "$RUNTIME" != "opencode" ] && [ -n "${RUNTIME_FILE:-}" ] && [ -f "$RUNTIME_FILE" ]; then
    # shellcheck disable=SC1090
    source "$RUNTIME_FILE"
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

  if declare -F ai_gateway_enabled_for_opencode >/dev/null && ai_gateway_enabled_for_opencode; then
    echo ""
    log "WP AI Gateway:"
    log "  Base URL:  $(ai_gateway_base_url)"
    log "  Env file:  $(ai_gateway_env_file)"
    log "  Model:     ${AI_GATEWAY_PROVIDER_ID}/${AI_GATEWAY_MODEL_ID}"
    log "  Route:     ${AI_GATEWAY_ROUTE_PROVIDER} / ${AI_GATEWAY_ROUTE_MODEL}"
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
  log "  ls $(runtime_skills_dir)              # installed upgrade skill"
}

# ============================================================================
# Execute
# ============================================================================

update_data_machine_plugins
configure_homeboy_dmc_worktree_provider_phase
sync_cli_transport_runtime
update_ai_gateway
sync_chat_bridge_config
check_opencode_json_drift
ai_gateway_configure_opencode
sync_skills
regenerate_agents_md
sync_claude_code_runtime
sync_runtime_signature
sync_runtime_instructions
update_chat_bridge_systemd
update_chat_bridge_launchd
update_datamachine_worker_service
remove_legacy_opencode_wrapper_phase
print_summary
