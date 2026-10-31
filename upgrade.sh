#!/bin/bash
#
# wp-coding-agents upgrade script
# Safely upgrade a live wp-coding-agents install without touching user state.
#
# Phases:
#   1. Detect environment (auto-detects local vs VPS, runtime, chat bridge).
#      Roadie is the only chat bridge; a Kimaki install is migrated to Roadie
#      in place (state copied, Kimaki unit disabled and kept as rollback).
#   2. Update setup-installed Data Machine plugins and WP Codebox
#      (subtree-packaged) to their latest tagged releases.
#      Roadie prompt config.
#        VPS:   /opt/roadie-config (plugins + prompt-config.yaml)
#        Local: $ROADIE_DATA_DIR/roadie-config/
#   4. Remove retired managed skills
#   5. Regenerate AGENTS.md via Data Machine compose
#   6. Smart systemd update (VPS only): roadie.service. Existing Environment=
#      lines are preserved (host custom values) while structural lines are
#      refreshed from the same template the install path uses
#      (bridges/roadie.sh::bridge_render_*).
#   7. Remove the retired runtime registry
#   8. Summary — prints the right restart + verify commands per bridge × env.
#
# Usage:
#   ./upgrade.sh                 # run all phases (auto-detects environment)
#   ./upgrade.sh --dry-run       # preview without changes
#   ./upgrade.sh --roadie-only   # only sync Roadie config + plugins
#   ./upgrade.sh --plugins-only  # only update Data Machine plugins
#   ./upgrade.sh --reconcile-services  # only sync provider, chat, and service state
#   ./upgrade.sh --skills-only   # only remove retired managed skills
#   ./upgrade.sh --agents-md-only  # only regenerate AGENTS.md
#   ./upgrade.sh --local --wp-path <path>  # local install (auto on macOS)
#
# Safety: NEVER touches WordPress DB, nginx, SSL, ~/.roadie/ auth state,
#   configured repository checkouts, agent memory files, or the running
#   chat-bridge service.
#
#   wp-coding-agents#718), and legacy `agent.build.prompt`/`agent.plan.prompt`
#   keys get migrated to a top-level `instructions` array (fixes Anthropic
#   Claude Max OAuth, see wp-coding-agents#60). User-added plugin entries are
#   left alone.
#
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
for lib in common grants detect install-source source-policy owned-source-discovery service-migration agent-state-ownership plugin-upgrade desired-state-reconciler convergence-orchestrator integration-adapters runtime-guidance-desired-state bridge-service-adapters wordpress data-machine carried-plugins wp-codebox homeboy ai-gateway skills cli-transport inbound-event-bridge wordpress-chat cli-channel runtime-signature runtime-guard source-reconcile agents-md-guidance webroot-backup-hygiene systems-capabilities self-upgrade codebox-database composer-provision; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

# Bridge dispatcher — auto-discovers bridges/*.sh. Each bridge owns its own
# render templates, sync, systemd/launchd update, and summary blocks.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"

# Guidance dispatcher — auto-discovers guidance/*.sh AGENTS.md section units.
# Adding a section is "drop a file in guidance/" — no edit here.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/guidance/_dispatch.sh"
source "$SCRIPT_DIR/services/datamachine-worker.sh"
source "$SCRIPT_DIR/services/homeboy-daemon.sh"
source "$SCRIPT_DIR/services/wordpress-service.sh"


# ============================================================================
# Parse arguments
# ============================================================================

DRY_RUN=false
ROADIE_ONLY=false
PLUGINS_ONLY=false
SKILLS_ONLY=false
AGENTS_MD_ONLY=false
RECONCILE_SERVICES_ONLY=false
SKIP_PLUGINS=false
WITH_AI_GATEWAY=false
ROTATE_AI_GATEWAY_TOKEN=false
WORDPRESS_SERVICE_REQUEST=""
WORDPRESS_SERVICE_HOST="${WORDPRESS_SERVICE_HOST:-}"
WORDPRESS_SERVICE_PORT="${WORDPRESS_SERVICE_PORT:-}"
WORDPRESS_SERVICE_WORKERS="${WORDPRESS_SERVICE_WORKERS:-}"
SHOW_HELP=false
SOURCE_MODE=""
SOURCE_MODE_EXPLICIT=false
OWNED_SOURCES=""
OWNED_SOURCES_EXPLICIT=false
OWNED_WRITABLE=""
OWNED_WRITABLE_EXPLICIT=false
SOURCE_LOG_PATHS=""
SOURCE_LOG_PATHS_EXPLICIT=false

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
AGENT_SLUG="${AGENT_SLUG:-}"
IS_STUDIO=false
CHAT_BRIDGE=""
HOMEBOY_MODE="${HOMEBOY_MODE:-auto}"
WITH_HOMEBOY="${WITH_HOMEBOY:-false}"
WORKSPACE_REPOSITORIES_EXPLICIT=false
# True when the operator forced the identity via --root / --non-root.
# Suppresses adopt_service_identity_from_units (existing-unit adoption).
SERVICE_USER_FORCED=false
# Set by --migrate-non-root: move an already-installed root agent onto a
# dedicated non-root service user, carrying its state across. See #93.
MIGRATE_NON_ROOT=false
RECONCILE_AGENT_STATE_OWNERSHIP_ONLY=false
MIGRATE_TARGET_USER="$SERVICE_MIGRATION_DEFAULT_USER"
initialize_roadie_overrides

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)       DRY_RUN=true; shift ;;
    --roadie-only)   ROADIE_ONLY=true; shift ;;
    --kimaki-only|--kimaki-unit|--kimaki-data-dir|--kimaki-lock-port)
      error "$1 was renamed to ${1/kimaki/roadie} (Kimaki was replaced by Roadie)." ;;
    --plugins-only)  PLUGINS_ONLY=true; shift ;;
    --skills-only)   SKILLS_ONLY=true; shift ;;
    --agents-md-only) AGENTS_MD_ONLY=true; shift ;;
    --reconcile-services) RECONCILE_SERVICES_ONLY=true; shift ;;
    --skip-plugins)  SKIP_PLUGINS=true; shift ;;
    --with-ai-gateway) WITH_AI_GATEWAY=true; shift ;;
    --with-datamachine-worker) DATAMACHINE_WORKER_REQUEST=enabled; shift ;;
    --no-datamachine-worker) DATAMACHINE_WORKER_REQUEST=disabled; shift ;;
    --with-wordpress-service) WORDPRESS_SERVICE_REQUEST=enabled; shift ;;
    --no-wordpress-service) WORDPRESS_SERVICE_REQUEST=disabled; shift ;;
    --wordpress-service-host) WORDPRESS_SERVICE_HOST="$2"; shift 2 ;;
    --wordpress-service-port) WORDPRESS_SERVICE_PORT="$2"; shift 2 ;;
    --wordpress-service-workers) WORDPRESS_SERVICE_WORKERS="$2"; shift 2 ;;
    --ai-gateway-provider) AI_GATEWAY_ROUTE_PROVIDER="$2"; shift 2 ;;
    --ai-gateway-model) AI_GATEWAY_ROUTE_MODEL="$2"; shift 2 ;;
    --ai-gateway-api-model) AI_GATEWAY_API_MODEL_ID="$2"; shift 2 ;;
    --rotate-ai-gateway-token) ROTATE_AI_GATEWAY_TOKEN=true; shift ;;
    --wordpress-chat-agent) WORDPRESS_CHAT_AGENT="$2"; shift 2 ;;
    --no-wordpress-chat) WORDPRESS_CHAT_DISABLE=true; shift ;;
    --host-config-repo) HOST_CONFIG_REPO="$2"; shift 2 ;;
    --host-config-path) HOST_CONFIG_PATH="$2"; shift 2 ;;
    --host-config-ref) HOST_CONFIG_REF="$2"; shift 2 ;;
    --source-mode|--posture) SOURCE_MODE="$2"; SOURCE_MODE_EXPLICIT=true; shift 2 ;;
    --workspace-repository) source_policy_begin_workspace_repository_declarations; source_policy_add_workspace_repository "$2"; shift 2 ;;
    --not-owned)     owned_discovery_add_exclusion "$2"; shift 2 ;;
    --owned-source|--managed-source) OWNED_SOURCES="${OWNED_SOURCES}${OWNED_SOURCES:+ }$2"; OWNED_SOURCES_EXPLICIT=true; shift 2 ;;
    --owned-writable|--managed-writable) OWNED_WRITABLE="${OWNED_WRITABLE}${OWNED_WRITABLE:+ }$2"; OWNED_WRITABLE_EXPLICIT=true; shift 2 ;;
    --log-path) SOURCE_LOG_PATHS="${SOURCE_LOG_PATHS}${SOURCE_LOG_PATHS:+ }$2"; SOURCE_LOG_PATHS_EXPLICIT=true; shift 2 ;;
    --systems-capabilities) SYSTEMS_CAPABILITIES_PROFILE="$2"; shift 2 ;;
    --systems-capabilities-only) SYSTEMS_CAPABILITIES_ONLY=true; shift ;;
    --runtime|--runtime=*) error "--runtime was removed with OpenCode (#751). Pi is the only runtime." ;;
    --wp-path)       EXISTING_WP="$2"; shift 2 ;;
    --agent-slug)    AGENT_SLUG="$2"; AGENT_SLUG_EXPLICIT=true; shift 2 ;;
    --roadie-unit)   ROADIE_UNIT="$2"; ROADIE_UNIT_EXPLICIT=true; shift 2 ;;
    --roadie-data-dir) ROADIE_DATA_DIR="$2"; ROADIE_DATA_DIR_EXPLICIT=true; shift 2 ;;
    --roadie-lock-port) ROADIE_LOCK_PORT="$2"; ROADIE_LOCK_PORT_EXPLICIT=true; shift 2 ;;
    --roadie-pool-url) ROADIE_POOL_URL="$2"; ROADIE_POOL_URL_EXPLICIT=true; shift 2 ;;
    --local)         LOCAL_MODE=true; RUN_AS_ROOT=false; shift ;;
    --root)          RUN_AS_ROOT=true;  SERVICE_USER_FORCED=true; shift ;;
    --non-root)      RUN_AS_ROOT=false; SERVICE_USER_FORCED=true; shift ;;
    --migrate-non-root) MIGRATE_NON_ROOT=true; RUN_AS_ROOT=false; SERVICE_USER_FORCED=true; shift ;;
    --migrate-user)  MIGRATE_TARGET_USER="$2"; shift 2 ;;
    --migrate-extra) service_migration_add_extra_path "$2"; shift 2 ;;
    --reconcile-agent-state-ownership) RECONCILE_AGENT_STATE_OWNERSHIP_ONLY=true; shift ;;
    --help|-h)       SHOW_HELP=true; shift ;;
    *)               shift ;;
  esac
done

systems_capabilities_validate_profile

if [ "$SHOW_HELP" = true ]; then
  # Delimiter is quoted ('HELP') so the body below is emitted literally: no
  # parameter expansion, no command substitution. This is deliberate — an
  # unquoted heredoc here previously let a `wp server` backtick in the prose
  # below execute as a live command substitution and block on a dev server
  # (#620). The one legitimate runtime value (the migration default user)
  # is injected afterward via a placeholder token substitution so the quoting
  # stays total and the value still has a single source of truth
  # (SERVICE_MIGRATION_DEFAULT_USER in lib/service-migration.sh).
  # Bash 3.2 misparses this quoted heredoc inside $(...), including later
  # case arms in its command-substitution parse. Read the literal body without
  # command substitution; EOF is the expected nonzero result of read -d ''.
  IFS= read -r -d '' HELP_TEXT << 'HELP' || true
wp-coding-agents upgrade script

Safely upgrade a live install without touching user state.

USAGE:
  ./upgrade.sh                  Run all phases (auto-detects local vs VPS)
  ./upgrade.sh --dry-run        Preview what would change
  ./upgrade.sh --roadie-only    Only sync the Roadie chat-bridge config
  ./upgrade.sh --plugins-only   Only update setup-installed Data Machine plugins
                                Uses 120s child / 480s total deadlines by default,
                                emits per-plugin terminal evidence, and exits 75
                                on a resumable partial failure. Override with
                                PLUGIN_UPDATE_PHASE_TIMEOUT_SECONDS and
                                PLUGIN_UPDATE_TOTAL_TIMEOUT_SECONDS.
  ./upgrade.sh --reconcile-services
                                 Only reconcile carried providers, Homeboy,
                                chat-bridge configuration, and service templates
  ./upgrade.sh --skills-only    Only remove retired managed skills
  ./upgrade.sh --agents-md-only Only regenerate AGENTS.md
  ./upgrade.sh --skip-plugins   Skip Data Machine plugin updates during full run
  ./upgrade.sh --systems-capabilities managed-vps
                                 Provision or repair the opt-in managed VPS
                                 systems-capability profile.
  ./upgrade.sh --systems-capabilities managed-vps --systems-capabilities-only
                                 Repair only the managed VPS host capability
                                  profile and its managed capability configuration.
  sudo ./upgrade.sh --reconcile-agent-state-ownership
                                 One-shot: hand root-owned agent state
                                 (persistent Roadie config, site runtime
                                 config, installation profile) to the service
                                 user so later non-root upgrades can maintain
                                 it. Exits without running other phases.
   ./upgrade.sh --source-mode <name>
   ./upgrade.sh --workspace-repository <absolute-git-checkout>
                               Where code changes land: workspace | owned
                               (default: the mode recorded at setup time).
                               Two shapes, not two levels. --posture is
                               accepted as a deprecated alias.
  ./upgrade.sh --not-owned <slug>
                               Plugin or theme slug that is NOT the site's,
                               despite classifying as owned — a premium or
                               vendor plugin, typically. Repeatable, recorded.
  ./upgrade.sh --owned-source <path>
                               wp-content path this site owns and may edit under
                               --source-mode owned. Repeatable. Replaces the
                               recorded set when supplied.
  ./upgrade.sh --wp-path <path> Override detected WordPress path
  ./upgrade.sh --agent-slug <s> Override Data Machine agent slug
  ./upgrade.sh --roadie-unit <u> Target Roadie systemd unit
  ./upgrade.sh --roadie-data-dir <path>
                                 Override the selected Roadie state directory
  ./upgrade.sh --roadie-lock-port <port>
                                 Override the selected Roadie lock port
  ./upgrade.sh --roadie-pool-url <url|local>
                                 Bill through a remote credential pool host
                                 (key: ROADIE_POOL_KEY env or <secrets>/pool-key;
                                 optional admin key for /credentials and /login:
                                 ROADIE_POOL_ADMIN_KEY env or <secrets>/pool-admin-key);
                                 "local" returns to the bot's own pool
  ./upgrade.sh --local          Local mode (no systemd; auto-on on macOS)
  ./upgrade.sh --root           Force root service identity (skips adoption
                                of the existing unit's User=)
  ./upgrade.sh --non-root       Force non-root service identity (User=pi)
  ./upgrade.sh --with-ai-gateway
                                Opt in to additive WP AI Gateway integration
                                for Pi: install/activate gateway stack,
                                configure route, reuse existing token env,
                                merge a wp-ai-gateway provider into Pi's
                                models.json, and set the Roadie unit's Pi
                                model to the gateway model. An existing
                                Without the flag, Pi stays on Roadie's
                                credential pool.
  ./upgrade.sh --wordpress-chat-agent <slug>
                                Opt in to WordPress-native chat for one agent:
                                writes the runtime-chat adapter config (slug ->
                                runtime ID), mints/reuses a shared signing
                                secret in a 0600 env file, runs the
                                inbound-event-connector as a managed service
                                next to Roadie, adds wordpress to the Roadie
                                platform list, and ensures a wordpress:<context>
                                channel entry. Once enabled, later upgrades
                                converge without repeating the flag.
  ./upgrade.sh --no-wordpress-chat
                                Disable WordPress-native chat: stop and remove
                                the inbound-event-connector service, delete the
                                durable env file, and drop wordpress from the
                                rendered Roadie platform list.
  ./upgrade.sh --host-config-repo <git-url>
  ./upgrade.sh --host-config-path <path-in-repo>
  ./upgrade.sh --host-config-ref <branch>
                                Record where the agent self-upgrade reads
                                host-declared opt-in flags from: a reviewed git
                                repo fetched into a root-owned bare mirror and
                                read at the merged ref (default main), never a
                                working tree. Values persist across upgrades.
  ./upgrade.sh --with-datamachine-worker
                                 Opt in to the managed bounded Data Machine
                                 worker. The choice persists across upgrades.
  ./upgrade.sh --no-datamachine-worker
                                 Disable the worker and remove its managed
                                 launchd or systemd service.
  ./upgrade.sh --with-wordpress-service
                                 Run this local WordPress site with a managed
                                 macOS launchd service backed by `wp server`.
  ./upgrade.sh --no-wordpress-service
                                 Disable and remove the managed local service.
  ./upgrade.sh --wordpress-service-host 127.0.0.1 --wordpress-service-port 8080
                                 Set the local WordPress bind address.
  ./upgrade.sh --wordpress-service-workers 4
                                 Set concurrent PHP workers (default: 4).
  ./upgrade.sh --with-ai-gateway --rotate-ai-gateway-token
                                Explicitly mint a replacement gateway token.
  ./upgrade.sh --with-ai-gateway --ai-gateway-provider openai --ai-gateway-model gpt-4o-mini
                                 Configure the WordPress gateway backend route.
  ./upgrade.sh --with-ai-gateway --ai-gateway-pi-provider openai --ai-gateway-pi-model gpt-5.6-sol --ai-gateway-api-model site-default
                                 Show the resolved provider/model identity in
                                 Pi while routing through site-default.

SERVICE IDENTITY:
  By default the upgrade adopts the service user from the EXISTING
  installed systemd unit (its User= line) rather than assuming root.
  The upgrade never changes the service identity implicitly; use
  --root / --non-root to change it deliberately.

  ./upgrade.sh --migrate-non-root
                                Move an install that currently runs as root
                                onto a dedicated non-root service user,
                                carrying the agent's state across. Use this
                                rather than --non-root, which only re-renders
                                the unit and would strand the agent's state
                                in /root.
  ./upgrade.sh --migrate-user <name>
                                Target user for --migrate-non-root
                                (default: __SERVICE_MIGRATION_DEFAULT_USER__).
  ./upgrade.sh --migrate-extra <path>
                                Carry an additional service-home-relative path
                                across. Repeatable. For install-specific state
                                the shipped inventory cannot know about.
                                Credential-shaped paths are refused.

  What migrates is an explicit, mode-aware allowlist: runtime state
  under every mode, plus the dev toolchain and forge credentials under
  workspace mode only. SSH keys, secret stores, and shell history are
  never migrated — they stay behind in root-owned /root, out of the agent's
  reach. That is the point of the migration, not a side effect.

CHAT BRIDGE:
  roadie (Discord). Kimaki installs are migrated to Roadie on upgrade.

ROADIE CONFIG TARGETS:
  VPS:   /opt/roadie-config/plugins
  Local: $ROADIE_DATA_DIR/roadie-config/plugins

NEVER TOUCHED:
  - CLAUDE.md runtime config
  - WordPress database, nginx, SSL certs
  - ~/.roadie/ auth state and OAuth tokens
   - Configured repository checkouts
  - Agent memory files (SOUL.md, MEMORY.md, USER.md, etc.)
  - Running chat-bridge service (never restarted automatically)

DEFAULT TOUCHES:
   - data-machine and wp-codebox — updates setup-installed sources. Non-git
     plugin directories are
    skipped. Use --skip-plugins to skip this phase.
  - Carried provider plugins, Homeboy provider configuration, chat-bridge
    configuration, and service templates are reconciled during a full upgrade
    or explicitly with --reconcile-services.
    removed. Those are internal config written into the public document
    root by older versions (#615). AGENTS.md rollback now uses a temp file
    .wp-coding-agents/backups/.

OPT-IN TOUCHES:
  - WP AI Gateway (--with-ai-gateway) — installs/updates wp-ai-gateway and
    ai-provider-for-openai, configures the gateway route, writes/reuses
    .wp-coding-agents/wp-ai-gateway.env, merges the gateway provider into Pi's
    and points ROADIE_PI_MODEL at the gateway model. Existing gateway tokens
    are reused unless --rotate-ai-gateway-token is also passed.
HELP
  printf '%s\n' "${HELP_TEXT//__SERVICE_MIGRATION_DEFAULT_USER__/$SERVICE_MIGRATION_DEFAULT_USER}"
  exit 0
fi

if [ "$PLUGINS_ONLY" = true ] && [ "$SKIP_PLUGINS" = true ]; then
  error "Cannot combine --plugins-only and --skip-plugins"
fi
if [ "$PLUGINS_ONLY" = true ] && { [ "$ROADIE_ONLY" = true ] || [ "$SKILLS_ONLY" = true ] || \
   [ "$AGENTS_MD_ONLY" = true ] || [ "$RECONCILE_SERVICES_ONLY" = true ] || \
   [ "${SYSTEMS_CAPABILITIES_ONLY:-false}" = true ] || [ "$MIGRATE_NON_ROOT" = true ]; }; then
  error "--plugins-only cannot be combined with service, runtime, migration, or other --*-only operations"
fi

# Every managed file below is copied out of $SCRIPT_DIR. Say so before the run
# starts when that tree is not clean default-branch, so a "successful" upgrade
# that reinstalls stale artifacts is visible rather than silent.
install_source_report_integrity

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

if [ "$PLUGINS_ONLY" = true ]; then
  detect_plugins_only_environment
  installation_profile_normalize "$INSTALLATION_OPERATION_PLUGINS_ONLY"
else
  # Load declarative setup intent before runtime selection and source-policy
  # resolution. The profile never contains transport argv, tokens, or secrets.
  installation_profile_load

# Run detect_environment first — it auto-sets LOCAL_MODE=true on macOS,
# which the chat bridge detection below depends on to pick the right branch.
detect_environment

# The source mode drives the plugin set, every runtime permission surface, and the
# AGENTS.md guidance. Resolve it from the value recorded at setup time so an
# upgrade converges a managed install instead of silently reverting it to
# engineering; --posture overrides and re-records.
source_policy_resolve_mode
if [ "$PLUGINS_ONLY" != true ] && [ "$ROADIE_ONLY" != true ] && [ "$SKILLS_ONLY" != true ] && \
   [ "$AGENTS_MD_ONLY" != true ] && [ "$RECONCILE_SERVICES_ONLY" != true ]; then
  source_policy_validate_workspace_repositories
fi
source_policy_resolve_owned_sources
source_policy_resolve_writable_paths
source_policy_resolve_log_paths
source_policy_resolve_workspace_dir
source_policy_resolve_homeboy_data_dir
if [ "$PLUGINS_ONLY" != true ] && [ "$ROADIE_ONLY" != true ] && [ "$SKILLS_ONLY" != true ] && \
   [ "$AGENTS_MD_ONLY" != true ] && [ "$RECONCILE_SERVICES_ONLY" != true ]; then
  source_policy_record_mode
  owned_discovery_record_exclusions
  source_policy_record_owned_sources
  source_policy_record_writable_paths
  source_policy_record_log_paths
fi
systems_capabilities_resolve_profile

# Detect chat bridge from installed services / installed binaries via the
# bridges/_dispatch.sh registry walk. See bridge_detect_local /
# bridge_detect_vps for the full probe order (launchd plists + command -v
# on local; systemd unit files on VPS). Priority order is set by
# BRIDGE_DETECTION_ORDER in _dispatch.sh (Roadie, including Kimaki installs to
# migrate).
#
if [ "$INSTALL_CHAT" != true ]; then
  CHAT_BRIDGE=""
elif [ -n "$CHAT_BRIDGE" ]; then
  log "Using chat bridge from installation profile: $CHAT_BRIDGE"
elif [ "$LOCAL_MODE" = true ]; then
  CHAT_BRIDGE=$(bridge_detect_local)
else
  CHAT_BRIDGE=$(bridge_detect_vps)
fi

# Load the active bridge's hooks (render, sync, update, summary) into this
# shell so the rest of upgrade.sh can call bridge_sync_config /
# bridge_update_systemd / bridge_render_systemd directly. No-op when
# detection found nothing — phase functions guard on $CHAT_BRIDGE.
# A profile recorded before the cutover names the retired bridges.
case "$CHAT_BRIDGE" in
  kimaki) CHAT_BRIDGE=roadie ;;
  cc-connect|telegram)
    warn "Chat bridge '$CHAT_BRIDGE' was removed; Roadie is the only bridge. Its service is left as is."
    CHAT_BRIDGE="" ;;
esac
if [ -n "$CHAT_BRIDGE" ] && bridge_file "$CHAT_BRIDGE" >/dev/null 2>&1; then
  bridge_load "$CHAT_BRIDGE"
fi

if [ "$CHAT_BRIDGE" = "roadie" ] && [ "$LOCAL_MODE" = false ]; then
  _roadie_resolve_instance
fi

# Snapshot the fully resolved invocation only after runtime, environment, source
# policy, and optional bridge intent have converged.
installation_profile_normalize "$INSTALLATION_OPERATION_UPGRADE"

# On upgrade, the installed unit's User= is the source of truth for the
# service identity. upgrade.sh defaults RUN_AS_ROOT=true, which on a
# to User=root — root-owned state files, broken next non-root start, and
# the root-homed-path dispatch trap (#198/#93) all over again. See #204.
# --root / --non-root force an explicit identity and skip adoption.
adopt_service_identity_from_units

# Converge credentials permissions only for ordinary non-root VPS upgrades,
# after both source-policy validation and service-identity adoption. Do not run
# setup's site-wide ownership/permission repair during an ordinary upgrade.
upgrade_harden_wp_config_permissions() {
  if [ "${LOCAL_MODE:-false}" != true ] && [ "$RUN_AS_ROOT" = false ] && \
     [ "$PLUGINS_ONLY" != true ] && [ "$ROADIE_ONLY" != true ] && \
     [ "$SKILLS_ONLY" != true ] && [ "$AGENTS_MD_ONLY" != true ] && \
     [ "$RECONCILE_SERVICES_ONLY" != true ]; then
    harden_wp_config_permissions "$SITE_PATH"
  fi
}
upgrade_harden_wp_config_permissions

# Converge the site root's own directory mode (#644). setup's one-time
# recursive grant does not survive an external directory replacement, and the
# service identity needs group-write at the root for AGENTS.md composition.
# BOTH upgrade identities converge this (#628): a non-root upgrade that
# cannot chmod a foreign-owned root gets one clear root-repair record
# instead of every later write failing, and a root-run upgrade (the default
# `sudo ./upgrade.sh` on a VPS) — which composes as the site owner through
# sudo — repairs the bit directly so the atomic rename can proceed.
upgrade_ensure_site_root_group_write() {
  if [ "${LOCAL_MODE:-false}" != true ] && [ "${EXTERNAL_WORDPRESS:-false}" != true ] && \
     [ "$PLUGINS_ONLY" != true ] && [ "$ROADIE_ONLY" != true ] && \
     [ "$SKILLS_ONLY" != true ] && \
     [ "$RECONCILE_SERVICES_ONLY" != true ]; then
    ensure_site_root_group_write "$SITE_PATH"
    if [ "${SITE_ROOT_GROUP_WRITE_CHANGED:-0}" -eq 1 ] && declare -p UPDATED_ITEMS >/dev/null 2>&1; then
      UPDATED_ITEMS+=("Site root group-write re-asserted ($SITE_PATH)")
    fi
    if [ "${SITE_ROOT_GROUP_WRITE_REPAIR_REQUIRED:-false}" = true ] && declare -p PENDING_ITEMS >/dev/null 2>&1; then
      PENDING_ITEMS+=("Site root group-write (root): $SITE_ROOT_GROUP_WRITE_REPAIR_COMMAND")
    fi
  fi
}

if [ "$DRY_RUN" = false ] && [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = true ] && [ "$EUID" -ne 0 ]; then
  error "Please run as root (sudo ./upgrade.sh), or use --non-root for installs whose service and WordPress files are writable by the current user."
fi

# Service identity, as the units on disk actually have it. --non-root and
# --migrate-non-root both set SERVICE_USER_FORCED=true, which suppresses
# adoption above, so this is the only thing that still knows what the install is
# running as TODAY — which both branches below need. Read-only.
INSTALLED_SERVICE_USER="$(service_migration_installed_user)"

# --non-root alone only forces the identity the units are RENDERED with. On an
# install already running as root that is a footgun (#93): the service user may
# not exist, and ROADIE_DATA_DIR is derived from the service home, so the agent
# gets repointed at an empty home while its session database, runtime auth, and
# toolchains stay behind in /root. Refuse early, before any mutation, and name
# the flag that does it properly rather than render a broken unit.
if [ "$MIGRATE_NON_ROOT" = false ] && [ "$LOCAL_MODE" = false ] && \
   [ "$RUN_AS_ROOT" = false ] && [ "$INSTALLED_SERVICE_USER" = "root" ]; then
  error "This install currently runs as root. --non-root only re-renders the unit; it would not create the service user or carry the agent's state across, leaving the service pointed at an empty home. Use --migrate-non-root to move it properly."
fi

log "Chat bridge: ${CHAT_BRIDGE:-none detected}"
log "Site path:   $SITE_PATH"
log "Service:     $SERVICE_USER"
if [ "$CHAT_BRIDGE" = "roadie" ]; then
  log "Roadie unit: $ROADIE_UNIT"
  log "Roadie data: $ROADIE_DATA_DIR"
  [ -z "$ROADIE_LOCK_PORT" ] || log "Roadie lock: $ROADIE_LOCK_PORT"
fi
if [ "$DRY_RUN" = true ]; then
  log "Dry-run mode: no changes will be made"
fi
echo ""
fi

# Track what was touched for the summary
UPDATED_ITEMS=()
PENDING_ITEMS=()
PLUGIN_UPDATE_FAILURES=()
# Managed units found in a bad runtime state. Reported, never acted on.
HEALTH_WARNINGS=()

# Service identity is final here; move Homeboy's data root before any unit
# renders HOMEBOY_DATA_DIR (#710).
homeboy_data_dir_migrate

if [ "${SYSTEMS_CAPABILITIES_ONLY:-false}" = true ]; then
  [ -n "${SYSTEMS_CAPABILITIES_PROFILE:-}" ] || error "--systems-capabilities-only requires --systems-capabilities <profile>"
  systems_capabilities_apply
  exit 0
fi

# Service identity migration (#93). Runs before any phase that renders a unit or
# writes into the service home, so everything downstream sees the new identity.
# Deliberately after UPDATED_ITEMS is declared — it reports into the summary.
if [ "$MIGRATE_NON_ROOT" = true ]; then
  if [ -z "$INSTALLED_SERVICE_USER" ]; then
    error "--migrate-non-root found no installed systemd unit to migrate. Use ./setup.sh --non-root for a fresh install."
  elif [ "$INSTALLED_SERVICE_USER" != "root" ]; then
    log "Install already runs as '$INSTALLED_SERVICE_USER' — nothing to migrate."
    MIGRATE_NON_ROOT=false
  else
    service_migration_preflight "$MIGRATE_TARGET_USER" "/root" "$SOURCE_MODE"
    service_migration_run "$MIGRATE_TARGET_USER" "/root" "$SOURCE_MODE"
    UPDATED_ITEMS+=("Service identity migrated: root -> $SERVICE_USER")
  fi
elif [ "$LOCAL_MODE" = false ] && [ "$SOURCE_MODE" = "owned" ] && \
     [ "$INSTALLED_SERVICE_USER" = "root" ]; then
  # Owned mode now defaults to non-root on fresh installs (#327), but an
  # existing install is NEVER flipped implicitly — that is the #204 rule, and
  # here it would additionally strand the agent's state in /root. Recommend the
  # migration and let the operator choose when to take the service down.
  warn "This owned-mode install runs as root. Fresh owned installs now default to"
  warn "a non-root service user: the edit denies are a guardrail, not containment,"
  warn "and a root service can reach every denied path through bash or wp eval."
  warn "Migrate when convenient:  sudo ./upgrade.sh --migrate-non-root"
fi

# Agent state follows the service identity (#598). As root, hand any
# root-owned agent-state root to the service user before phases write into it;
# as the service user, audit once and report a single consolidated root-repair
# record instead of per-file permission noise from every later phase.
if [ "$RECONCILE_AGENT_STATE_OWNERSHIP_ONLY" = true ]; then
  [ "$LOCAL_MODE" = true ] || [ "$EUID" -eq 0 ] || error "--reconcile-agent-state-ownership must run as root (sudo ./upgrade.sh --reconcile-agent-state-ownership)"
  agent_state_ownership_reconcile
  if [ "${AGENT_STATE_OWNERSHIP_CHANGED:-0}" -eq 0 ]; then
    log "Agent state already owned by ${SERVICE_USER}; nothing to reconcile."
  fi
  exit 0
fi
if [ "$EUID" -eq 0 ]; then
  agent_state_ownership_reconcile
else
  agent_state_ownership_audit
fi

# Restore the site root's group-write before any phase writes at the root
# (#644); the summary picks the repair-or-report result up from
# UPDATED_ITEMS / PENDING_ITEMS.
upgrade_ensure_site_root_group_write

# A root upgrade may discover the system Homeboy binary, but managed non-root
# services must execute the service-owned copy instead.
homeboy_provision_service_bin



# ============================================================================
# Helpers
# ============================================================================

_run_filter_active() {
  # Returns 0 if the given phase should run given the *-only flags.
  # Usage: _run_filter_active <flag_name>   (e.g. ROADIE_ONLY)
  local phase="$1"
  # If any --*-only flag is set, only that one runs
  if [ "$ROADIE_ONLY" = true ] || [ "$PLUGINS_ONLY" = true ] || [ "$SKILLS_ONLY" = true ] || [ "$AGENTS_MD_ONLY" = true ] || [ "$RECONCILE_SERVICES_ONLY" = true ]; then
    case "$phase" in
      roadie)    [ "$ROADIE_ONLY" = true ] || [ "$RECONCILE_SERVICES_ONLY" = true ]; return $? ;;
      plugins)   [ "$PLUGINS_ONLY" = true ]; return $? ;;
      skills)    [ "$SKILLS_ONLY" = true ]; return $? ;;
      agents-md) [ "$AGENTS_MD_ONLY" = true ]; return $? ;;
      reconciliation|transport|systemd) [ "$RECONCILE_SERVICES_ONLY" = true ]; return $? ;;
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
  if [ "$PLUGINS_ONLY" = true ]; then
    reconcile_installed_plugins
    return $?
  fi
  local status=0
  upgrade_data_machine_plugins || status=$PLUGIN_UPDATE_EXIT_PARTIAL
  plugin_update_execute wp-codebox update_wp_codebox_plugin_subtree || status=$PLUGIN_UPDATE_EXIT_PARTIAL
  plugin_update_verify_installed_plugins data-machine wp-codebox || status=$PLUGIN_UPDATE_EXIT_PARTIAL
  return "$status"
}

_reconcile_data_machine_plugin() {
  plugin_update_execute data-machine update_plugin_to_latest_tag data-machine https://github.com/Extra-Chill/data-machine.git
}

_reconcile_wp_codebox_plugin() {
  plugin_update_execute wp-codebox update_wp_codebox_plugin_subtree
}

_reconcile_installed_plugins_verify() {
  [ "${#RECONCILER_INSTALLED_PLUGIN_SLUGS[@]}" -gt 0 ] || return 0
  plugin_update_verify_installed_plugins "${RECONCILER_INSTALLED_PLUGIN_SLUGS[@]}"
}

# The plugins-only operation has no runtime, bridge, Homeboy, guidance, or
# service adapters. Its profile plans only setup-installed plugin records.
reconcile_installed_plugins() {
  local plugin_dir status=0
  [ "${INSTALLATION_PROFILE_OPERATION:-}" = "$INSTALLATION_OPERATION_PLUGINS_ONLY" ] || \
    error "Installed plugin reconciliation requires a plugins-only installation profile"
  reconciler_plan_reset
  RECONCILER_INSTALLED_PLUGIN_SLUGS=()
  log "[desired-state] profile=$(installation_profile_record)"

  for plugin_dir in "${INSTALLATION_PROFILE_PLUGIN_CANDIDATES[@]}"; do
    [ -d "$INSTALLATION_PROFILE_SITE_PATH/wp-content/plugins/$plugin_dir" ] || {
      log "[$plugin_dir] terminal=skipped reason=not-installed"
      continue
    }
    RECONCILER_INSTALLED_PLUGIN_SLUGS+=("$plugin_dir")
    case "$plugin_dir" in
      data-machine) reconciler_plan_add "plugins.data-machine" plugins.reconcile.data-machine _reconcile_data_machine_plugin ;;
      wp-codebox) reconciler_plan_add "plugins.wp-codebox" plugins.reconcile.wp-codebox _reconcile_wp_codebox_plugin ;;
    esac
  done

  reconciler_plan_set_verify _reconcile_installed_plugins_verify
  reconciler_apply_plan || status=$?
  reconciler_verify_plan || status=$PLUGIN_UPDATE_EXIT_PARTIAL
  return "$status"
}

reconcile_provider_and_service_state() {
  : # Migrated integrations run through convergence_run.
}

sync_cli_transport_runtime() {
  _run_filter_active transport || return 0

  log "Phase 2b: Syncing CLI dispatch transport..."
  cli_transport_install
  inbound_event_bridge_install
  runtime_guard_sync
  source_reconcile_sync
  source_reconcile_run
}

update_ai_gateway() {
  _run_filter_active reconciliation || return 0
  ai_gateway_apply
}

update_wordpress_chat() {
  _run_filter_active reconciliation || return 0
  [ "${EXTERNAL_WORDPRESS:-false}" != true ] || return 0
  wordpress_chat_apply
}

# ============================================================================
# Phase 3: Sync chat-bridge config (Roadie: release, secrets, managed config)
# ============================================================================

sync_chat_bridge_config() {
  : # Migrated bridge synchronization runs through convergence_run.
}


# ============================================================================
# Phase 4: Remove retired managed skills (the upgrade skill is replaced by
# `roadie upgrade` / /upgrade-and-restart, see lib/self-upgrade.sh)
# ============================================================================

sync_skills() {
  _run_filter_active skills || return 0
  log "Phase 4: Removing retired managed skills..."
  remove_retired_skills
}

# ============================================================================
# Phase 5: Regenerate AGENTS.md
# ============================================================================

regenerate_agents_md() {
  _run_filter_active agents-md || return 0

  log "Phase 5: Regenerating AGENTS.md..."

  local AGENTS_MD="$SITE_PATH/AGENTS.md"
  local CLAUDE_MD="$SITE_PATH/CLAUDE.md"
  # Pre-compose copy used to roll back a failed/stale compose and to diff the
  # result. It is a transaction journal, not an archive: AGENTS.md is a
  # generated file recomposed from live Data Machine state, so a historical
  # copy has no value once the new one verifies. Keep it in TMPDIR — never in
  # $SITE_PATH, which on a WordPress install is the public document root
  # (#615) — and remove it on every exit path.
  local BACKUP
  BACKUP="$(mktemp "${TMPDIR:-/tmp}/wp-coding-agents-agents-md.XXXXXX")"

  if [ "$DRY_RUN" = true ]; then
    rm -f "$BACKUP"
    echo -e "${BLUE}[dry-run]${NC} Would stage a temporary pre-compose copy of $AGENTS_MD for rollback"
    echo -e "${BLUE}[dry-run]${NC} Would sync WordPress coding-agent boundary guidance mu-plugin"
    echo -e "${BLUE}[dry-run]${NC} Would sync Homeboy AGENTS.md CLI guidance mu-plugin"
    echo -e "${BLUE}[dry-run]${NC} Would run (as ${SERVICE_USER:-caller}): $(wp_cli_transport_display) datamachine memory compose AGENTS.md"
    echo -e "${BLUE}[dry-run]${NC} Would symlink $CLAUDE_MD → AGENTS.md (Claude-model context)"
    return 0
  fi

  # Backup existing (compose writes in-place to the registered location).
  # Every unsuccessful or stale recompose restores this exact user state.
  local HAD_AGENTS_MD=false
  if [ -f "$AGENTS_MD" ]; then
    HAD_AGENTS_MD=true
    cp "$AGENTS_MD" "$BACKUP"
  else
    rm -f "$BACKUP"
  fi

  # `datamachine memory compose AGENTS.md` writes in-place to the registered
  # composable file path. It does NOT accept an arbitrary output path —
  # the filename must be a registered MemoryFileRegistry entry.
  #
  # Compose as the webroot owner, not merely the service user. Generated
  # guidance includes `--allow-root` when composed by root; upgrade.sh may run
  # under sudo, so root composition would misdescribe a non-root agent's
  # environment (#93, #322).
  #
  # Permissions are still normalized afterward: compose writes as whichever
  # identity ran it, and without this every other writer is locked out until the
  # next normalize.
  if (cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md >/dev/null); then
    local expected_producer composed_producer provenance_status gate_status
    expected_producer="version=$(agents_md_guidance_producer_version) source=$(agents_md_guidance_producer_source)"
    composed_producer="$(agents_md_guidance_composed_producer "$AGENTS_MD")"
    agents_md_guidance_verify_composed_provenance "$AGENTS_MD" || provenance_status=$?
    if [ "${provenance_status:-0}" = 1 ]; then
      if [ -z "$composed_producer" ]; then
        gate_status=0
        agents_md_guidance_composition_gate wp_run_as_site_owner || gate_status=$?
        case "$gate_status" in
          1|2) log "  Data Machine AGENTS.md composition is disabled or unavailable; provenance verification is gated" ;;
          *)
            warn "  AGENTS.md is missing wp-coding-agents provenance after compose (expected $expected_producer)"
            agents_md_guidance_restore_precompose_state "$AGENTS_MD" "$BACKUP" "$HAD_AGENTS_MD"
            warn "  Restored AGENTS.md to its pre-compose state"
            return 1
            ;;
        esac
      else
        warn "  AGENTS.md remains stale after compose ($composed_producer; expected $expected_producer)"
        agents_md_guidance_restore_precompose_state "$AGENTS_MD" "$BACKUP" "$HAD_AGENTS_MD"
        warn "  Restored AGENTS.md to its pre-compose state"
        return 1
      fi
    fi
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
    rm -f "$BACKUP"
    webroot_backup_prune_legacy "$SITE_PATH"
    webroot_backup_prune_managed "$SITE_PATH"
  else
    warn "  datamachine memory compose failed"
    # wp_run_as_site_owner prints the redacted compose stderr above this
    # (#628): an unwritable site root makes Data Machine refuse the atomic
    # rename, and that refusal is what names the repair.
    warn "  Most often the site root is not writable by the compose identity; the summary's site-root group-write entry names the one-time repair."
    # Restore a partial write, or remove a newly-created partial file.
    agents_md_guidance_restore_precompose_state "$AGENTS_MD" "$BACKUP" "$HAD_AGENTS_MD"
    rm -f "$BACKUP"
    warn "  Restored AGENTS.md to its pre-compose state"
    return 1
  fi

  # Symlink CLAUDE.md → AGENTS.md so Claude-model sessions get the same DM context.
  # duplicating content or risking drift on AGENTS.md regeneration. Relative target
  # ensures the symlink survives directory moves.
  # See: Extra-Chill/wp-coding-agents#108
  if [ -f "$AGENTS_MD" ]; then
    # Skip if CLAUDE.md exists as a regular file — it is user-owned.
    if [ -L "$CLAUDE_MD" ] || [ ! -e "$CLAUDE_MD" ]; then
      # The rename creates a directory entry, so like compose it needs write
      # access to $SITE_PATH itself — not to AGENTS.md (#628).
      if (cd "$SITE_PATH" && ln -sf AGENTS.md CLAUDE.md); then
        log "  Symlinked CLAUDE.md → AGENTS.md (covers Claude-model pi sessions)"
      else
        warn "  Could not symlink CLAUDE.md → AGENTS.md: $SITE_PATH is not writable by this identity; restoring the site root's group-write (see the summary) restores it."
      fi
    else
      log "  CLAUDE.md exists as a regular file — leaving it alone (runtime-managed)"
    fi
  fi
}


sync_runtime_instructions() {
  : # Runtime instructions are shared adapter records.
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
  : # Migrated bridge service update runs through convergence_run.
}

update_chat_bridge_launchd() {
  : # Migrated bridge service update runs through convergence_run.
}

reconcile_datamachine_worker_service() {
  : # Migrated optional service runs through convergence_run.
}

reconcile_wordpress_service() {
  : # Migrated optional service runs through convergence_run.
}

# ============================================================================
# Phase 8: Summary
# ============================================================================

print_summary() {
  echo ""
  echo "=========================================="
  if [ "$PLUGINS_ONLY" = true ] && [ "${PLUGIN_ONLY_EXIT_STATUS:-0}" -ne 0 ]; then
    warn "Plugin upgrade partially completed."
  elif [ "${CONVERGENCE_EXIT_STATUS:-0}" -ne 0 ]; then
    warn "Desired-state convergence partially completed."
  elif [ "${AGENTS_MD_EXIT_STATUS:-0}" -ne 0 ]; then
    # Named here rather than left to the reader: every other phase converged,
    # so without this line a non-zero exit has no visible cause in the summary.
    warn "Upgrade completed except AGENTS.md — composition failed; see above."
  else
    log "Upgrade complete."
  fi
  echo "=========================================="

  if [ ${#UPDATED_ITEMS[@]} -eq 0 ]; then
    log "Nothing changed — everything was already up to date."
  else
    log "Updated:"
    for item in "${UPDATED_ITEMS[@]}"; do
      log "  - $item"
    done
  fi

  # Runtime health is reported separately from file reconciliation. "Nothing
  # changed" describes the unit files, not whether the services are running
  # (#576).
  if [ ${#HEALTH_WARNINGS[@]} -gt 0 ]; then
    echo ""
    warn "Service health:"
    for item in "${HEALTH_WARNINGS[@]}"; do
      warn "  - $item"
    done
  fi

  if [ ${#PENDING_ITEMS[@]} -gt 0 ]; then
    echo ""
    warn "Pending:"
    for item in "${PENDING_ITEMS[@]}"; do
      warn "  - $item"
    done
  fi


  if [ "${AGENT_STATE_OWNERSHIP_ROOT_REPAIR_REQUIRED:-false}" = true ]; then
    echo ""
    warn "Agent state ownership: root repair required (${#AGENT_STATE_OWNERSHIP_UNWRITABLE[@]} root(s) not maintainable by $(id -un))."
    warn "  $AGENT_STATE_OWNERSHIP_ROOT_REPAIR_COMMAND"
  fi

  if declare -F ai_gateway_enabled >/dev/null && ai_gateway_enabled; then
    echo ""
    log "WP AI Gateway:"
    log "  Base URL:  $(ai_gateway_base_url)"
    log "  Env file:  $(ai_gateway_env_file)"
    log "  Pi model:  $(ai_gateway_pi_model)"
    log "  Model:     ${AI_GATEWAY_PROVIDER_ID}/${AI_GATEWAY_MODEL_ID}"
    log "  API model: $(ai_gateway_api_model_id)"
    log "  Route:     ${AI_GATEWAY_ROUTE_PROVIDER} / ${AI_GATEWAY_ROUTE_MODEL}"
  fi

  echo ""
  if [ "$PLUGINS_ONLY" = true ]; then
    plugin_update_print_terminal_summary
    [ "${PLUGIN_ONLY_EXIT_STATUS:-0}" -eq 0 ] || reconciler_print_partial_evidence
    echo ""
    _print_plugins_only_verify_block
  else
    _print_bridge_restart_hint
    _print_verify_block
  fi
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

  # A failed bridge reconcile may leave the previous Roadie installed while
  # config for the new release is already on disk; restarting then would
  # point every session at provider routes the installed bridge cannot
  # serve (#725).
  if [ "${BRIDGE_RECONCILE_FAILED:-false}" = true ]; then
    warn "Do NOT restart $(bridge_display_name) — the chat-bridge reconcile failed above and the pinned release may not be installed."
    warn "Re-run the upgrade once the failure is fixed, then restart."
    echo ""
    return 0
  fi

  local env display cmd
  env=$(_resolve_bridge_env)
  display=$(bridge_display_name)

  if [ "$CHAT_BRIDGE" = "roadie" ] && [ "$env" != "local-manual" ]; then
    warn "Restart $display when ready (Roadie resumes runs the restart interrupts):"
  else
    warn "Restart $display when ready (active chat sessions will die):"
  fi
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

    # Optional per-bridge addendum (Roadie's managed-config checks). Falls
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

  log "  $(wp_cli_transport_display) plugin get data-machine --field=version --path=$SITE_PATH $WP_ROOT_FLAG"
  log "  cat $SITE_PATH/AGENTS.md | head -20   # agent instructions"
}

_print_plugins_only_verify_block() {
  log "Verify:"
  log "  $(wp_cli_transport_display) plugin get data-machine --fields=name,status,version --format=json --skip-plugins --path=$SITE_PATH $WP_ROOT_FLAG"
}

# ============================================================================
# Execute
# ============================================================================

PLUGIN_ONLY_EXIT_STATUS=0
CONVERGENCE_EXIT_STATUS=0
AGENTS_MD_EXIT_STATUS=0
# The bridge record carries the pinned Roadie install (bridges/<bridge>).
# When its reconcile fails, dependent steps that assume the new Roadie must
# not apply — and the restart hint must be withheld (#725).
BRIDGE_RECONCILE_FAILED=false
update_data_machine_plugins || PLUGIN_ONLY_EXIT_STATUS=$?
if [ "$PLUGINS_ONLY" != true ] && [ "$SKILLS_ONLY" != true ] && [ "${EXTERNAL_WORDPRESS:-false}" != true ]; then
  # The shared WordPress chat secret must exist before the bridge renders
  # reference its env file or inline its values (#779). No-op unless the
  # activation flag was passed or a previous opt-in wrote the env file.
  wordpress_chat_write_env
fi
if [ "$PLUGINS_ONLY" != true ]; then
  CONVERGENCE_ENTRYPOINT="$SCRIPT_DIR/upgrade.sh"
  CONVERGENCE_REPLAY_ARGUMENTS="--wp-path $(printf '%q' "$SITE_PATH")"
  [ "$DRY_RUN" = true ] && CONVERGENCE_REPLAY_ARGUMENTS="--dry-run $CONVERGENCE_REPLAY_ARGUMENTS"
  CONVERGENCE_SCOPE=all
  if [ "$RECONCILE_SERVICES_ONLY" = true ]; then CONVERGENCE_SCOPE=services; fi
  if [ "$ROADIE_ONLY" = true ]; then CONVERGENCE_SCOPE=bridge; fi
  if [ "$AGENTS_MD_ONLY" = true ]; then CONVERGENCE_SCOPE=agents-md; fi
  if [ "$SKILLS_ONLY" != true ]; then
    convergence_run "$INSTALLATION_OPERATION_UPGRADE" || CONVERGENCE_EXIT_STATUS=$?
  fi
fi
if [ "$PLUGINS_ONLY" != true ]; then
  case " ${RECONCILER_FAILED_RECORDS[*]:-} " in
    *' bridges.'*) BRIDGE_RECONCILE_FAILED=true ;;
  esac
fi
reconcile_provider_and_service_state
sync_cli_transport_runtime
update_ai_gateway
update_wordpress_chat
sync_chat_bridge_config
if _run_filter_active systemd; then
  systems_capabilities_apply
  self_upgrade_apply
fi
sync_skills
# Captured, not aborted. This is the only phase function here with a non-zero
# return path, and under `set -e` a bare call made one stale memory file end the
# run: eleven reconciliation phases and print_summary never happened, and the
# log simply stopped mid-phase with nothing saying the rest had been skipped.
# A failed compose is still worth a non-zero exit at the end — see the
# AGENTS_MD_EXIT_STATUS check below — but not worth abandoning service
# reconciliation halfway through.
regenerate_agents_md || AGENTS_MD_EXIT_STATUS=$?
if _run_filter_active agents-md; then
  runtime_guidance_retire_codex_projection
fi
sync_runtime_instructions
update_chat_bridge_systemd
update_chat_bridge_launchd
reconcile_wordpress_service
reconcile_datamachine_worker_service
if [ "$PLUGINS_ONLY" != true ]; then
  installation_profile_write
fi
print_summary
if [ "$PLUGINS_ONLY" = true ]; then
  exit "$PLUGIN_ONLY_EXIT_STATUS"
fi
if [ "$CONVERGENCE_EXIT_STATUS" -ne 0 ]; then
  reconciler_print_partial_evidence
  exit "$CONVERGENCE_EXIT_STATUS"
fi
if [ "$AGENTS_MD_EXIT_STATUS" -ne 0 ]; then
  exit "$AGENTS_MD_EXIT_STATUS"
fi
