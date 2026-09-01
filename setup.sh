#!/bin/bash
#
# wp-coding-agents setup script
# Bootstrap WordPress + Data Machine + a coding agent on a VPS or local machine
# with a pluggable chat interface layer and auto-discovered runtime modules.
#
# Usage:
#   Fresh VPS:        SITE_DOMAIN=example.com ./setup.sh
#   Existing WP:      EXISTING_WP=/var/www/mysite ./setup.sh --existing
#   Local (macOS):    EXISTING_WP=/path/to/wordpress ./setup.sh --local
#   Claude Code:      ./setup.sh --runtime claude-code
#   Without Discord:  ./setup.sh --no-chat
#
# Data Machine is the substrate wp-coding-agents composes on top of — memory
# files (SOUL/MEMORY/USER/RULES/SITE), auto-composed AGENTS.md,
# wp-coding-agents upgrade skill,
# MCP surface. Workspace policy and repository authority belong to
# wp-coding-agents. It is not optional. Uninstall the plugin
# later if you don't want it.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared modules
for lib in common detect source-policy owned-source-discovery desired-state-reconciler convergence-orchestrator integration-adapters runtime-guidance-desired-state bridge-service-adapters wordpress external-wordpress infrastructure data-machine carried-plugins homeboy ai-gateway skills summary cli-transport inbound-event-bridge cli-channel runtime-signature runtime-guard source-reconcile agents-md-guidance opencode-subagents systems-capabilities; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

# Bridge dispatcher — auto-discovers bridges/*.sh. Adding a new bridge is
# "drop a file in bridges/" — no edit here.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"

# Guidance dispatcher — auto-discovers guidance/*.sh AGENTS.md section units.
# Adding a section is "drop a file in guidance/" — no edit here.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/guidance/_dispatch.sh"
source "$SCRIPT_DIR/services/datamachine-worker.sh"
source "$SCRIPT_DIR/services/wordpress-service.sh"

# Discover available runtimes from runtimes/ directory
AVAILABLE_RUNTIMES=()
for runtime_file in "$SCRIPT_DIR"/runtimes/*.sh; do
  [ -f "$runtime_file" ] || continue
  name=$(basename "$runtime_file" .sh)
  AVAILABLE_RUNTIMES+=("$name")
done

# ============================================================================
# Parse arguments
# ============================================================================

MODE="fresh"
LOCAL_MODE=false
SKIP_DEPS=false
SKIP_SSL=false
INSTALL_CHAT=true
CHAT_BRIDGE=""
SHOW_HELP=false
DRY_RUN=false
RUN_AS_ROOT=true
SERVICE_USER_FORCED=false
MULTISITE=false
MULTISITE_TYPE="subdirectory"
INSTALL_SKILLS=true
SKILLS_ONLY=false
RUNTIME_ONLY=false
WITH_HOMEBOY=false
WITH_AI_GATEWAY=false
WITH_CLAUDE_CODE_AUTH=true
ROTATE_AI_GATEWAY_TOKEN=false
WORDPRESS_SERVICE_REQUEST=""
WORDPRESS_SERVICE_HOST="${WORDPRESS_SERVICE_HOST:-}"
WORDPRESS_SERVICE_PORT="${WORDPRESS_SERVICE_PORT:-}"
RUNTIME=""
CHAT_BRIDGE_EXPLICIT=false
HOMEBOY_MODE="auto"
SOURCE_MODE=""
SOURCE_MODE_EXPLICIT=false
OWNED_SOURCES=""
OWNED_SOURCES_EXPLICIT=false
OWNED_WRITABLE=""
OWNED_WRITABLE_EXPLICIT=false
SOURCE_LOG_PATHS=""
SOURCE_LOG_PATHS_EXPLICIT=false
HOMEBOY_PROJECT_ID="${HOMEBOY_PROJECT_ID:-}"
DETECTED_RUNTIMES=()
IS_STUDIO=false
EXTERNAL_WORDPRESS=false
initialize_kimaki_overrides

while [[ $# -gt 0 ]]; do
  case $1 in
    --skills-only)
      SKILLS_ONLY=true
      INSTALL_SKILLS=true
      shift
      ;;
    --existing)
      MODE="existing"
      shift
      ;;
    --wp-path)
      MODE="existing"
      EXISTING_WP="$2"
      shift 2
      ;;
    --external-wordpress)
      EXTERNAL_WORDPRESS=true
      MODE="existing"
      LOCAL_MODE=true
      SKIP_DEPS=true
      SKIP_SSL=true
      RUN_AS_ROOT=false
      shift
      ;;
    --runtime-project-root)
      RUNTIME_PROJECT_ROOT="$2"
      shift 2
      ;;
    --wordpress-path)
      WORDPRESS_PATH="$2"
      shift 2
      ;;
    --wordpress-user)
      WORDPRESS_USER="$2"
      shift 2
      ;;
    --local)
      LOCAL_MODE=true
      MODE="existing"
      SKIP_DEPS=true
      SKIP_SSL=true
      RUN_AS_ROOT=false
      shift
      ;;
    --skip-deps)
      SKIP_DEPS=true
      shift
      ;;
    --no-chat)
      INSTALL_CHAT=false
      shift
      ;;
    --chat)
      CHAT_BRIDGE="$2"
      CHAT_BRIDGE_EXPLICIT=true
      shift 2
      ;;
    --skip-ssl)
      SKIP_SSL=true
      shift
      ;;
    --root)
      RUN_AS_ROOT=true
      SERVICE_USER_FORCED=true
      shift
      ;;
    --non-root)
      RUN_AS_ROOT=false
      SERVICE_USER_FORCED=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --multisite)
      MULTISITE=true
      shift
      ;;
    --subdomain)
      MULTISITE_TYPE="subdomain"
      shift
      ;;
    --no-skills)
      INSTALL_SKILLS=false
      shift
      ;;
    --with-homeboy)
      HOMEBOY_MODE="enabled"
      WITH_HOMEBOY=true
      shift
      ;;
    --with-datamachine-worker)
      DATAMACHINE_WORKER_REQUEST=enabled
      shift
      ;;
    --with-wordpress-service)
      WORDPRESS_SERVICE_REQUEST=enabled
      shift
      ;;
    --no-wordpress-service)
      WORDPRESS_SERVICE_REQUEST=disabled
      shift
      ;;
    --wordpress-service-host)
      WORDPRESS_SERVICE_HOST="$2"
      shift 2
      ;;
    --wordpress-service-port)
      WORDPRESS_SERVICE_PORT="$2"
      shift 2
      ;;
    --no-datamachine-worker)
      DATAMACHINE_WORKER_REQUEST=disabled
      shift
      ;;
    --with-ai-gateway)
      WITH_AI_GATEWAY=true
      shift
      ;;
    --with-claude-code-auth)
      WITH_CLAUDE_CODE_AUTH=true
      shift
      ;;
    --no-claude-code-auth)
      WITH_CLAUDE_CODE_AUTH=false
      shift
      ;;
    --ai-gateway-provider)
      AI_GATEWAY_ROUTE_PROVIDER="$2"
      shift 2
      ;;
    --ai-gateway-model)
      AI_GATEWAY_ROUTE_MODEL="$2"
      shift 2
      ;;
    --ai-gateway-opencode-provider)
      AI_GATEWAY_PROVIDER_ID="$2"
      shift 2
      ;;
    --ai-gateway-opencode-model)
      AI_GATEWAY_MODEL_ID="$2"
      shift 2
      ;;
    --ai-gateway-api-model)
      AI_GATEWAY_API_MODEL_ID="$2"
      shift 2
      ;;
    --rotate-ai-gateway-token)
      ROTATE_AI_GATEWAY_TOKEN=true
      shift
      ;;
    --no-homeboy)
      HOMEBOY_MODE="disabled"
      shift
      ;;
    --homeboy-project-id)
      HOMEBOY_PROJECT_ID="$2"
      shift 2
      ;;
    --runtime-only)
      RUNTIME_ONLY=true
      MODE="existing"
      shift
      ;;
    --runtime)
      RUNTIME="$2"
      shift 2
      ;;
    --source-mode|--posture)
      SOURCE_MODE="$2"
      SOURCE_MODE_EXPLICIT=true
      shift 2
      ;;
    --workspace-repository)
      source_policy_add_workspace_repository "$2"
      shift 2
      ;;
    --not-owned)
      owned_discovery_add_exclusion "$2"
      shift 2
      ;;
    --owned-source|--managed-source)
      OWNED_SOURCES="${OWNED_SOURCES}${OWNED_SOURCES:+ }$2"
      OWNED_SOURCES_EXPLICIT=true
      shift 2
      ;;
    --owned-writable|--managed-writable)
      OWNED_WRITABLE="${OWNED_WRITABLE}${OWNED_WRITABLE:+ }$2"
      OWNED_WRITABLE_EXPLICIT=true
      shift 2
      ;;
    --log-path)
      SOURCE_LOG_PATHS="${SOURCE_LOG_PATHS}${SOURCE_LOG_PATHS:+ }$2"
      SOURCE_LOG_PATHS_EXPLICIT=true
      shift 2
      ;;
    --systems-capabilities)
      SYSTEMS_CAPABILITIES_PROFILE="$2"
      shift 2
      ;;
    --agent-slug)
      AGENT_SLUG="$2"
      AGENT_SLUG_EXPLICIT=true
      shift 2
      ;;
    --agent-name)
      AGENT_NAME="$2"
      shift 2
      ;;
    --kimaki-unit)
      KIMAKI_UNIT="$2"
      KIMAKI_UNIT_EXPLICIT=true
      shift 2
      ;;
    --kimaki-data-dir)
      KIMAKI_DATA_DIR="$2"
      KIMAKI_DATA_DIR_EXPLICIT=true
      shift 2
      ;;
    --kimaki-lock-port)
      KIMAKI_LOCK_PORT="$2"
      KIMAKI_LOCK_PORT_EXPLICIT=true
      shift 2
      ;;
    --help|-h)
      SHOW_HELP=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

systems_capabilities_validate_profile

if [ "$SHOW_HELP" = true ]; then
  cat << HELP
wp-coding-agents setup script

Bootstrap WordPress + Data Machine + a coding agent on a VPS or local machine,
with a pluggable chat bridge for talking to your agent.

Available runtimes: ${AVAILABLE_RUNTIMES[*]}

USAGE:
  Fresh VPS:          SITE_DOMAIN=example.com ./setup.sh
  Existing WordPress: EXISTING_WP=/var/www/mysite ./setup.sh --existing
  Local (macOS/Linux): EXISTING_WP=/path/to/wordpress ./setup.sh --local
  With Claude Code:   ./setup.sh --runtime claude-code --existing
  With Codex:         ./setup.sh --runtime codex --existing --no-chat

OPTIONS:
  --existing         Add agent to existing WordPress (skip WP install)
  --wp-path <path>   Path to WordPress root (implies --existing)
  --external-wordpress Attach a local runtime to WordPress through a supplied control transport
  --runtime-project-root <path>
                      Local runtime root for config, skills, and projected context
  --wordpress-path <path>
                      WordPress-side path passed only to the control transport
  --wordpress-user <user>
                      Optional WordPress user passed only to the control transport
  --local            Local machine mode (skip infrastructure: no apt, nginx,
                     systemd, SSL, service users). Works with any local
                     WordPress install (Studio, MAMP, manual, etc.)
  --runtime <name>   Coding agent runtime (auto-detected if omitted)
                     Available: ${AVAILABLE_RUNTIMES[*]}
   --source-mode <name>
                     Where the agent's code changes land. These are two shapes,
                     not two levels — neither is "more access" than the other.
                      workspace (default): installed source is read-only
                        reference and every change goes through declared
                        repositories, git, and GitHub. Recorded by review.
                     owned: the agent edits the site's own declared components
                       in place; no workspace, no git, no GitHub, and
                        repository workspace is not used. Recorded by the
                       operator's out-of-band capture. For managed agentic
                       hosting.
                     Recorded on the install so upgrades converge without
                     repeating the flag. (--posture is accepted as a
                      deprecated alias; engineering=workspace, managed=owned.)
   --workspace-repository <absolute-git-checkout>
                      Declares a repository authority for workspace mode.
                      Repeatable; no repository path is inferred.
  --not-owned <slug> Plugin or theme slug that is NOT the site's despite
                     classifying as owned — a premium or vendor plugin,
                     typically. Repeatable. Recorded on the install.
  --owned-source <path>
                     wp-content path this site owns and the agent may edit
                     under --source-mode owned. Repeatable. Must be a plugin or
                     theme directory, e.g.
                     wp-content/themes/acme or wp-content/plugins/acme-core.
                     Everything not declared stays read-only, including
                     third-party plugins. Declare exactly what the operator's
                     harvest captures.
  --agent-slug <s>   Override Data Machine agent slug (default: derived from domain)
  --agent-name <n>   Override Data Machine agent display name (default: blogname)
  --kimaki-unit <u>  Kimaki systemd unit (default: kimaki.service)
  --kimaki-data-dir <path>
                     Kimaki state directory (default: <service-home>/.kimaki)
  --kimaki-lock-port <port>
                     Kimaki lock port (default: Kimaki's built-in default)
  --no-chat          Skip chat bridge installation
  --chat <bridge>    Chat bridge to install (default: kimaki for opencode,
                     cc-connect for claude-code, none for codex)
                     Supported: kimaki (Discord), cc-connect, telegram
  --skip-deps        Skip apt package installation
  --multisite        Convert to WordPress Multisite (subdirectory by default)
  --subdomain        Use subdomain multisite (requires wildcard DNS; use with --multisite)
  --no-skills        Skip installing the wp-coding-agents upgrade skill
  --systems-capabilities managed-vps
                       Opt in to root-managed journald and debug-log rotation on
                       a VPS.
  --with-homeboy     Create/update a Homeboy project and install/verify the
                       WordPress Homeboy extension
  --with-datamachine-worker
                      Opt in to a managed service that runs one bounded Data
                      Machine worker pass every two minutes. This does not run
                      generic WP-Cron events.
  --no-datamachine-worker
                      Disable the worker and remove its managed service state.
  --with-wordpress-service
                      Run this local WordPress site with a managed macOS
                      launchd service backed by `wp server`.
  --no-wordpress-service
                      Disable and remove the managed local WordPress service.
  --wordpress-service-host <host>
                      Bind host for the local service (default: 127.0.0.1).
  --wordpress-service-port <port>
                      Bind port for the local service (default: 8080).
  --with-ai-gateway  Opt in to WP AI Gateway setup for OpenCode runtimes.
                     Installs/activates the gateway/provider stack, configures
                     the gateway route, mints/reuses a gateway token, and adds
                     an OpenAI-compatible provider to opencode.json.
  --ai-gateway-provider <id>
                     Backend WordPress AI Client provider for site-default
                     routing (default: openai)
  --ai-gateway-model <id>
                      Backend provider model for site-default routing
                      (default: gpt-4o-mini)
  --ai-gateway-opencode-provider <id>
                      Provider identity shown by OpenCode
                      (default: wp-ai-gateway)
  --ai-gateway-opencode-model <id>
                      Model identity shown by OpenCode
                      (default: site-default)
  --ai-gateway-api-model <id>
                      Model ID sent to WP AI Gateway (default: the OpenCode
                      model identity)
  --rotate-ai-gateway-token
                      Mint a new gateway token instead of reusing the existing
                      .opencode/wp-ai-gateway.env value
  --no-claude-code-auth
                      Skip the managed direct OpenCode Claude Pro/Max OAuth
                      auth plugin. Installed by default for OpenCode runtimes.
  --no-homeboy       Skip Homeboy project setup, even if homeboy is installed
  --homeboy-project-id <id>
                     Override Homeboy project ID (default: agent/site slug)
  --skills-only      Only run wp-coding-agents upgrade skill installation on existing site
  --runtime-only     Only run runtime setup on an existing agent install
                     (use with --runtime <name> to add another runtime)
  --skip-ssl         Skip SSL/HTTPS configuration
  --root             Run agent as root (default)
  --non-root         Run agent as dedicated service user (opencode)
  --dry-run          Print commands without executing
  --help, -h         Show this help

ENVIRONMENT VARIABLES:
  SITE_DOMAIN        Domain for fresh install (required)
  SITE_PATH          WordPress path (default: /var/www/\$SITE_DOMAIN)
  EXISTING_WP        Path to existing WordPress (required with --existing)
  DB_NAME            Database name (fresh install only)
  DB_USER            Database user (fresh install only)
  DB_PASS            Database password (auto-generated if not set)
  AGENT_SLUG         Override agent slug (default: derived from domain)
  AGENT_NAME         Override agent display name (default: blogname)
  HOMEBOY_PROJECT_ID Override Homeboy project ID (default: agent/site slug)
  HOMEBOY_SERVER_ID  Homeboy server ID for VPS project registration
  OPENCODE_MODEL     Override default model (e.g., anthropic/claude-sonnet-4-20250514)
  OPENCODE_SMALL_MODEL  Override small model (e.g., anthropic/claude-haiku-4-5)
  AI_GATEWAY_ROUTE_PROVIDER  Backend provider used by --with-ai-gateway
  AI_GATEWAY_ROUTE_MODEL     Backend model used by --with-ai-gateway
  AI_GATEWAY_PROVIDER_ID     Provider identity shown by OpenCode
  AI_GATEWAY_MODEL_ID        Model identity shown by OpenCode
  AI_GATEWAY_API_MODEL_ID    Model ID sent to WP AI Gateway
  AI_GATEWAY_SITE_URL        Public site URL for OPENAI_BASE_URL override
  WITH_CLAUDE_CODE_AUTH      false to skip direct OpenCode Claude Pro/Max auth
  KIMAKI_BOT_TOKEN          Bot token or gateway clientId:clientSecret
                            (skip interactive setup)
  KIMAKI_UNIT               Kimaki systemd unit (default: kimaki.service)
  KIMAKI_DATA_DIR           Kimaki state directory
  KIMAKI_LOCK_PORT          Kimaki lock port
  KIMAKI_PACKAGE_ROOT       Kimaki dist directory used for external credential setup
  KIMAKI_GATEWAY_APP_ID     Gateway application ID override
  KIMAKI_GATEWAY_PROXY_REST_URL
                            Gateway REST URL override
  TELEGRAM_BOT_TOKEN        Telegram bot token from @BotFather (--chat telegram)
  TELEGRAM_ALLOWED_USER_ID  Numeric Telegram user ID (--chat telegram)
  OPENCODE_MODEL_PROVIDER   Default model provider for Telegram bot (default: opencode)
  OPENCODE_MODEL_ID         Default model ID for Telegram bot (default: big-pickle)
  EXTRA_PLUGINS      Space-separated slug:url pairs for additional plugins
  MCP_SERVERS        JSON object merged into runtime config (requires jq)
  WP_CLI_TRANSPORT_JSON
                     Explicit WP-CLI argv JSON (e.g., '["studio","wp"]')
  WP_CMD             Legacy command-string input; parsed once into argv
  WP_CONTROL_TRANSPORT_JSON  JSON argv array used by --external-wordpress
  HOMEBOY_EXTENSIONS_SOURCE  Homeboy extensions git URL/path
                     (default: https://github.com/Extra-Chill/homeboy-extensions.git)

MIGRATION WORKFLOW:
  1. On old server: Export database and wp-content
     mysqldump dbname > backup.sql
     tar -czf wp-content.tar.gz wp-content/

  2. On new VPS: Import and run setup
     mysql dbname < backup.sql
     tar -xzf wp-content.tar.gz -C /var/www/mysite/
     EXISTING_WP=/var/www/mysite ./setup.sh --existing
HELP
  exit 0
fi

# ============================================================================
# Runtime resolution
# ============================================================================

# Auto-detect runtime(s).
#
# RUNTIME is the "primary" runtime — the one that drives runtime_install,
# runtime_generate_config, runtime_install_hooks, and the chat-bridge default.
# First-match cascade: claude-code > opencode > codex.
#
# DETECTED_RUNTIMES is the list of ALL runtimes whose binary is present. On a
# machine with claude, opencode, and codex installed, the upgrade skill gets
# installed into every detected runtime's skills dir (see install_skills in lib/skills.sh).
# Explicit --runtime <name> narrows both lists to that single runtime.
if [ -n "$RUNTIME" ]; then
  # User passed --runtime explicitly — respect it, single-runtime mode.
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
    # Nothing installed yet — default to opencode (will be installed).
    DETECTED_RUNTIMES=("opencode")
  fi
  # Primary = first match in the cascade above.
  RUNTIME="${DETECTED_RUNTIMES[0]}"
fi

# Source the selected runtime
RUNTIME_FILE="$SCRIPT_DIR/runtimes/${RUNTIME}.sh"
if [ ! -f "$RUNTIME_FILE" ]; then
  error "Unknown runtime: $RUNTIME. Available: ${AVAILABLE_RUNTIMES[*]}"
fi
source "$RUNTIME_FILE"

# Set default chat bridge based on runtime
if [ -z "$CHAT_BRIDGE" ]; then
  case "$RUNTIME" in
    claude-code) CHAT_BRIDGE="cc-connect" ;;
    codex)       INSTALL_CHAT=false ;;
    *)                       CHAT_BRIDGE="kimaki" ;;
  esac
fi

if [ "$RUNTIME" = "codex" ] && [ "$INSTALL_CHAT" = true ]; then
  if [ "$CHAT_BRIDGE_EXPLICIT" = true ]; then
    error "Codex runtime does not currently support chat bridges; use --no-chat or omit --chat."
  fi
  INSTALL_CHAT=false
  CHAT_BRIDGE=""
fi

if [ "$EXTERNAL_WORDPRESS" = true ] && [ "$RUNTIME" != "opencode" ]; then
  error "--external-wordpress currently requires --runtime opencode"
fi

# ============================================================================
# Execute
# ============================================================================

external_wordpress_prepare_transport
detect_environment
external_wordpress_validate

# The source mode must resolve BEFORE anything that enforces it: the plugin set, the
# runtime permission surfaces, and the AGENTS.md guidance all derive from it.
source_policy_resolve_mode
source_policy_validate_workspace_repositories
source_policy_resolve_owned_sources
source_policy_resolve_writable_paths
source_policy_resolve_log_paths
source_policy_resolve_workspace_dir
source_policy_assert_runtime_supports_mode

# Owned mode defaults to a non-root service user (#327). Must run after the mode
# resolves and before create_service_user / setup_service_permissions, both of
# which branch on RUN_AS_ROOT.
detect_apply_source_mode_identity_default

if [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ] && [ "$LOCAL_MODE" = false ]; then
  bridge_load kimaki
  _kimaki_resolve_instance
fi

# Persist only declarative installation intent after environment and optional
# component selection have settled. Credentials remain runtime-only inputs.
installation_profile_normalize "$INSTALLATION_OPERATION_SETUP"

# --skills-only early exit
if [ "$SKILLS_ONLY" = true ]; then
  install_skills
  print_skills_summary
  exit 0
fi

# --runtime-only skips infrastructure phases (plugins, database, agent creation).
# Use when adding a runtime to an existing agent that already has plugins installed.
if [ "$RUNTIME_ONLY" != true ]; then
  if [ "$EXTERNAL_WORDPRESS" = true ]; then
    log "External WordPress profile: site installation and mutation phases are skipped"
  else
    install_system_deps
    setup_database
    install_wordpress
    setup_multisite
    create_service_user
    install_data_machine
    create_dm_agent
    install_extra_plugins
    setup_nginx
    setup_ssl
    setup_service_permissions
  fi
fi

if [ "$RUNTIME_ONLY" != true ] && [ "$EXTERNAL_WORDPRESS" != true ]; then
  source_policy_record_mode
  owned_discovery_record_exclusions
  source_policy_record_owned_sources
  source_policy_record_writable_paths
  source_policy_record_log_paths
  setup_ai_gateway
fi

[ "$RUNTIME_ONLY" != true ] && systems_capabilities_apply
CONVERGENCE_ENTRYPOINT="$SCRIPT_DIR/setup.sh"
CONVERGENCE_REPLAY_ARGUMENTS="--wp-path $(printf '%q' "${SITE_PATH:-${EXISTING_WP:-}}")"
[ "$DRY_RUN" = true ] && CONVERGENCE_REPLAY_ARGUMENTS="--dry-run $CONVERGENCE_REPLAY_ARGUMENTS"
[ "$RUNTIME_ONLY" != true ] || CONVERGENCE_SCOPE=runtime
if convergence_run "$INSTALLATION_OPERATION_SETUP"; then :; else
  CONVERGENCE_EXIT_STATUS=$?
  reconciler_print_partial_evidence
  exit "$CONVERGENCE_EXIT_STATUS"
fi
[ "$RUNTIME_ONLY" != true ] && ai_gateway_configure_opencode
[ "$RUNTIME_ONLY" != true ] && opencode_project_subagents_optional
[ "$RUNTIME_ONLY" != true ] && install_skills
if [ "$RUNTIME_ONLY" != true ]; then if [ "$EXTERNAL_WORDPRESS" != true ]; then cli_transport_install; inbound_event_bridge_install; else inbound_event_connector_install; fi; fi
# Install the reconciler, then run it once so a fresh install converges the same
# way a live change will.
if [ "$RUNTIME_ONLY" != true ] && [ "$EXTERNAL_WORDPRESS" != true ]; then source_reconcile_sync; source_reconcile_run; fi
[ "$RUNTIME_ONLY" != true ] && installation_profile_write
print_summary
