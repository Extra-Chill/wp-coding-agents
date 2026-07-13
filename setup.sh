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
# workspace primitive, MCP surface. It is not optional. Uninstall the plugin
# later if you don't want it.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared modules
for lib in common detect wordpress infrastructure data-machine carried-plugins homeboy ai-gateway skills summary cli-transport cli-channel runtime-signature agents-md-guidance; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

# Bridge dispatcher — auto-discovers bridges/*.sh. Adding a new bridge is
# "drop a file in bridges/" — no edit here.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/services/datamachine-worker.sh"

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
RUNTIME=""
CHAT_BRIDGE_EXPLICIT=false
HOMEBOY_MODE="auto"
HOMEBOY_PROJECT_ID="${HOMEBOY_PROJECT_ID:-}"
DETECTED_RUNTIMES=()
IS_STUDIO=false
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
    --ai-gateway-opencode-model)
      AI_GATEWAY_MODEL_ID="$2"
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
  --local            Local machine mode (skip infrastructure: no apt, nginx,
                     systemd, SSL, service users). Works with any local
                     WordPress install (Studio, MAMP, manual, etc.)
  --runtime <name>   Coding agent runtime (auto-detected if omitted)
                     Available: ${AVAILABLE_RUNTIMES[*]}
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
  --with-homeboy     Create/update a Homeboy project and install/verify the
                      WordPress Homeboy extension
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
  --ai-gateway-opencode-model <id>
                     OpenCode model ID exposed by the gateway provider
                     (default: site-default)
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
  AI_GATEWAY_MODEL_ID        OpenCode gateway model id (default: site-default)
  AI_GATEWAY_SITE_URL        Public site URL for OPENAI_BASE_URL override
  WITH_CLAUDE_CODE_AUTH      false to skip direct OpenCode Claude Pro/Max auth
  KIMAKI_BOT_TOKEN          Discord bot token (skip interactive setup)
  KIMAKI_UNIT               Kimaki systemd unit (default: kimaki.service)
  KIMAKI_DATA_DIR           Kimaki state directory
  KIMAKI_LOCK_PORT          Kimaki lock port
  TELEGRAM_BOT_TOKEN        Telegram bot token from @BotFather (--chat telegram)
  TELEGRAM_ALLOWED_USER_ID  Numeric Telegram user ID (--chat telegram)
  OPENCODE_MODEL_PROVIDER   Default model provider for Telegram bot (default: opencode)
  OPENCODE_MODEL_ID         Default model ID for Telegram bot (default: big-pickle)
  EXTRA_PLUGINS      Space-separated slug:url pairs for additional plugins
  MCP_SERVERS        JSON object merged into runtime config (requires jq)
  WP_CMD             Override WP-CLI command (default: wp; e.g., "studio wp")
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

# ============================================================================
# Execute
# ============================================================================

detect_environment

if [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ] && [ "$LOCAL_MODE" = false ]; then
  bridge_load kimaki
  _kimaki_resolve_instance
fi

# --skills-only early exit
if [ "$SKILLS_ONLY" = true ]; then
  install_skills
  print_skills_summary
  exit 0
fi

# --runtime-only skips infrastructure phases (plugins, database, agent creation).
# Use when adding a runtime to an existing agent that already has plugins installed.
if [ "$RUNTIME_ONLY" != true ]; then
  install_system_deps
  setup_database
  install_wordpress
  setup_multisite
  create_service_user
  install_data_machine
  create_dm_agent
  sync_carried_plugins
  install_extra_plugins
  setup_homeboy_project
  configure_homeboy_dmc_worktree_provider
  setup_nginx
  setup_ssl
  setup_service_permissions
fi

setup_ai_gateway

runtime_install
runtime_discover_dm_paths
runtime_generate_config
ai_gateway_configure_opencode
runtime_install_hooks
configure_homeboy_wordpress_extension
runtime_generate_instructions
runtime_merge_mcp_servers
install_skills
cli_transport_install
install_chat_bridge
datamachine_worker_install
print_summary
