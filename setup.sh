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
# files (SOUL/MEMORY/USER/RULES/SITE), auto-composed AGENTS.md, skills,
# workspace primitive, MCP surface. It is not optional. Uninstall the plugin
# later if you don't want it.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared modules
for lib in common detect wordpress infrastructure data-machine skills chat-bridge summary; do
  source "$SCRIPT_DIR/lib/${lib}.sh"
done

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
MULTISITE=false
MULTISITE_TYPE="subdirectory"
INSTALL_SKILLS=true
SKILLS_ONLY=false
RUNTIME_ONLY=false
RUNTIME=""
IS_STUDIO=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skills-only)
      SKILLS_ONLY=true
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
      shift 2
      ;;
    --skip-ssl)
      SKIP_SSL=true
      shift
      ;;
    --root)
      RUN_AS_ROOT=true
      shift
      ;;
    --non-root)
      RUN_AS_ROOT=false
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
      shift 2
      ;;
    --agent-name)
      AGENT_NAME="$2"
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
  With Studio Code:   ./setup.sh --runtime studio-code --local

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
  --no-chat          Skip chat bridge installation
  --chat <bridge>    Chat bridge to install (default: kimaki for opencode,
                     cc-connect for claude-code)
                     Supported: kimaki (Discord), cc-connect, telegram
  --skip-deps        Skip apt package installation
  --multisite        Convert to WordPress Multisite (subdirectory by default)
  --subdomain        Use subdomain multisite (requires wildcard DNS; use with --multisite)
  --no-skills        Skip WordPress agent skills installation
  --skills-only      Only run skills installation on existing site
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
  OPENCODE_MODEL     Override default model (e.g., anthropic/claude-sonnet-4-20250514)
  OPENCODE_SMALL_MODEL  Override small model (e.g., anthropic/claude-haiku-4-5)
  KIMAKI_BOT_TOKEN          Discord bot token (skip interactive setup)
  TELEGRAM_BOT_TOKEN        Telegram bot token from @BotFather (--chat telegram)
  TELEGRAM_ALLOWED_USER_ID  Numeric Telegram user ID (--chat telegram)
  OPENCODE_MODEL_PROVIDER   Default model provider for Telegram bot (default: opencode)
  OPENCODE_MODEL_ID         Default model ID for Telegram bot (default: big-pickle)
  EXTRA_PLUGINS      Space-separated slug:url pairs for additional plugins
  MCP_SERVERS        JSON object merged into runtime config (requires jq)
  WP_CMD             Override WP-CLI command (default: wp; e.g., "studio wp")

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

# Auto-detect runtime if not specified
if [ -z "$RUNTIME" ]; then
  if command -v studio &>/dev/null && [ "${IS_STUDIO:-false}" = true ]; then
    RUNTIME="studio-code"
  elif command -v claude &>/dev/null; then
    RUNTIME="claude-code"
  elif command -v opencode &>/dev/null; then
    RUNTIME="opencode"
  else
    # Default to opencode (will be installed)
    RUNTIME="opencode"
  fi
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
    claude-code|studio-code) CHAT_BRIDGE="cc-connect" ;;
    *)                       CHAT_BRIDGE="kimaki" ;;
  esac
fi

# ============================================================================
# Execute
# ============================================================================

detect_environment

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
  install_extra_plugins
  setup_nginx
  setup_ssl
  setup_service_permissions
fi

runtime_install
runtime_discover_dm_paths
runtime_generate_config
runtime_install_hooks
runtime_generate_instructions
runtime_merge_mcp_servers
install_skills
install_chat_bridge
print_summary
