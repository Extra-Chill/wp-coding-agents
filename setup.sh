#!/bin/bash
#
# wp-opencode setup script
# Bootstrap WordPress + Data Machine + OpenCode on a VPS or local machine
# with a pluggable chat interface layer.
#
# Usage:
#   Fresh VPS:        SITE_DOMAIN=example.com ./setup.sh
#   Existing WP:      EXISTING_WP=/var/www/mysite ./setup.sh --existing
#   Local (macOS):    EXISTING_WP=/path/to/wordpress ./setup.sh --local
#   Without Discord:  ./setup.sh --no-chat
#   Without DM:       ./setup.sh --no-data-machine
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[wp-opencode]${NC} $1"; }
warn() { echo -e "${YELLOW}[wp-opencode]${NC} $1"; }
error() { echo -e "${RED}[wp-opencode]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[wp-opencode]${NC} $1"; }

run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $*"
  else
    "$@"
  fi
}

write_file() {
  local file_path="$1"
  local content="$2"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write to $file_path"
  else
    echo "$content" > "$file_path"
  fi
}

# Run a WP-CLI command with the correct flags for the current platform.
# Usage: wp_cmd option get siteurl
#        wp_cmd plugin activate data-machine
wp_cmd() {
  # shellcheck disable=SC2086
  run_cmd $WP_CMD "$@" $WP_ROOT_FLAG --path="$SITE_PATH"
}

# Activate a plugin, handling multisite --url= branching.
# Usage: activate_plugin data-machine
activate_plugin() {
  local slug="$1"
  if [ "$MULTISITE" = true ]; then
    wp_cmd plugin activate "$slug" --url="$SITE_DOMAIN" || \
      warn "$slug may already be active"
  else
    wp_cmd plugin activate "$slug" || \
      warn "$slug may already be active"
  fi
}

# Install a WordPress plugin from a git repo.
# Handles: clone, composer install, activate, file ownership.
# Usage: install_plugin data-machine https://github.com/Extra-Chill/data-machine.git
install_plugin() {
  local slug="$1"
  local repo_url="$2"
  local plugin_dir="$SITE_PATH/wp-content/plugins/$slug"

  if [ ! -d "$plugin_dir" ] || [ "$DRY_RUN" = true ]; then
    run_cmd git clone "$repo_url" "$plugin_dir"
    if [ -f "$plugin_dir/composer.json" ] || [ "$DRY_RUN" = true ]; then
      run_cmd env COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev --no-interaction --working-dir="$plugin_dir" || \
        warn "Composer failed, some $slug features may not work"
    fi
    if [ -f "$plugin_dir/package.json" ] || [ "$DRY_RUN" = true ]; then
      log "Building $slug JS assets..."
      run_cmd npm install --prefix "$plugin_dir" || \
        warn "npm install failed for $slug"
      run_cmd npm run build --prefix "$plugin_dir" || \
        warn "npm build failed for $slug — admin pages may not work"
    fi
  fi

  activate_plugin "$slug"
  fix_ownership "$plugin_dir"
}

# Set file ownership to www-data (no-op in local mode).
# Usage: fix_ownership /path/to/dir
fix_ownership() {
  if [ "$LOCAL_MODE" = false ]; then
    run_cmd chown -R www-data:www-data "$1"
  fi
}

# Install agent skills from a git repo.
# Clones the repo, copies directories containing SKILL.md to the target.
# Usage: install_skills_from_repo https://github.com/WordPress/agent-skills.git "WordPress agent skills"
install_skills_from_repo() {
  local repo_url="$1"
  local label="${2:-skills}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} git clone --depth 1 $repo_url (extract skill dirs to $SKILLS_DIR)"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  if git clone --depth 1 "$repo_url" "$tmp_dir" 2>/dev/null; then
    for skill_dir in "$tmp_dir"/*/; do
      local skill_name
      skill_name=$(basename "$skill_dir")
      if [ -f "$skill_dir/SKILL.md" ]; then
        cp -r "$skill_dir" "$SKILLS_DIR/$skill_name"
        log "  Installed skill: $skill_name"
      fi
    done
    rm -rf "$tmp_dir"
    log "$label installed (latest version)"
  else
    warn "Could not clone $label from $repo_url"
    rm -rf "$tmp_dir"
  fi
}

# ============================================================================
# Parse arguments
# ============================================================================

MODE="fresh"
LOCAL_MODE=false
SKIP_DEPS=false
SKIP_SSL=false
INSTALL_DATA_MACHINE=true
INSTALL_CHAT=true
CHAT_BRIDGE="kimaki"
SHOW_HELP=false
DRY_RUN=false
RUN_AS_ROOT=true
MULTISITE=false
MULTISITE_TYPE="subdirectory"
INSTALL_SKILLS=true
SKILLS_ONLY=false

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
    --no-data-machine)
      INSTALL_DATA_MACHINE=false
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
  cat << 'HELP'
wp-opencode setup script

Bootstrap WordPress + Data Machine + OpenCode on a VPS or local machine,
with a pluggable chat bridge for talking to your agent.

USAGE:
  Fresh VPS:          SITE_DOMAIN=example.com ./setup.sh
  Existing WordPress: EXISTING_WP=/var/www/mysite ./setup.sh --existing
  Local (macOS/Linux): EXISTING_WP=/path/to/wordpress ./setup.sh --local

OPTIONS:
  --existing         Add OpenCode to existing WordPress (skip WP install)
  --local            Local machine mode (skip infrastructure: no apt, nginx,
                     systemd, SSL, service users). Works with any local
                     WordPress install (Studio, MAMP, manual, etc.)
  --no-data-machine  Skip Data Machine plugin (no persistent memory/scheduling)
  --no-chat          Skip chat bridge installation
  --chat <bridge>    Chat bridge to install (default: kimaki)
                     Supported: kimaki (Discord), telegram
  --skip-deps        Skip apt package installation
  --multisite        Convert to WordPress Multisite (subdirectory by default)
  --subdomain        Use subdomain multisite (requires wildcard DNS; use with --multisite)
  --no-skills        Skip WordPress agent skills installation
  --skills-only      Only run skills installation (Phase 8.5) on existing site
  --skip-ssl         Skip SSL/HTTPS configuration
  --root             Run agent as root (default)
  --non-root         Run agent as dedicated service user (opencode)
  --dry-run          Print commands without executing
  --help, -h         Show this help

ENVIRONMENT VARIABLES:
  SITE_DOMAIN        Domain for fresh install (required)
  SITE_PATH          WordPress path (default: /var/www/$SITE_DOMAIN)
  EXISTING_WP        Path to existing WordPress (required with --existing)
  DB_NAME            Database name (fresh install only)
  DB_USER            Database user (fresh install only)
  DB_PASS            Database password (auto-generated if not set)
  AGENT_SLUG         Override agent slug (default: derived from domain)
  OPENCODE_MODEL     Override default model (e.g., anthropic/claude-sonnet-4-20250514)
  OPENCODE_SMALL_MODEL  Override small model (e.g., anthropic/claude-haiku-4-5)
  KIMAKI_BOT_TOKEN          Discord bot token (skip interactive setup)
  TELEGRAM_BOT_TOKEN        Telegram bot token from @BotFather (--chat telegram)
  TELEGRAM_ALLOWED_USER_ID  Numeric Telegram user ID (--chat telegram)
  OPENCODE_MODEL_PROVIDER   Default model provider for Telegram bot (default: opencode)
  OPENCODE_MODEL_ID         Default model ID for Telegram bot (default: big-pickle)
  EXTRA_PLUGINS      Space-separated slug:url pairs for additional plugins
  MCP_SERVERS        JSON object merged into opencode.json .mcp key (requires jq)
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

# Detect OS and platform
PLATFORM="linux"
case "$(uname -s)" in
  Darwin) PLATFORM="mac"; OS="macos" ;;
  Linux)
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      OS=$ID
    else
      if [ "$DRY_RUN" = true ]; then
        OS="ubuntu"
        warn "Cannot detect OS (dry-run mode), assuming Ubuntu"
      else
        error "Cannot detect OS. This script supports Ubuntu/Debian."
      fi
    fi
    ;;
  *) error "Unsupported OS: $(uname -s)" ;;
esac

# Auto-enable local mode on macOS
if [ "$PLATFORM" = "mac" ] && [ "$LOCAL_MODE" = false ]; then
  LOCAL_MODE=true
  MODE="existing"
  SKIP_DEPS=true
  SKIP_SSL=true
  RUN_AS_ROOT=false
  log "macOS detected — enabling local mode automatically"
fi

# Validate Linux distro (only matters for fresh/VPS installs)
if [ "$PLATFORM" = "linux" ] && [ "$LOCAL_MODE" = false ]; then
  if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    if [ "$DRY_RUN" = true ]; then
      warn "Unsupported OS: $OS (continuing in dry-run mode)"
      OS="ubuntu"
    else
      error "VPS mode supports Ubuntu/Debian only. Detected: $OS. Use --local for local installs."
    fi
  fi
fi

# Check root (not required in local mode)
if [ "$DRY_RUN" = false ] && [ "$LOCAL_MODE" = false ] && [ "$EUID" -ne 0 ]; then
  error "Please run as root (sudo ./setup.sh). Use --local for local installs."
fi

# WP-CLI flag: --allow-root on VPS, omit on local
if [ "$LOCAL_MODE" = true ]; then
  WP_ROOT_FLAG=""
else
  WP_ROOT_FLAG="--allow-root"
fi

# WP-CLI command: override with WP_CMD="studio wp" for WordPress Studio, etc.
WP_CMD="${WP_CMD:-wp}"

log "Detected OS: $OS (platform: $PLATFORM, local: $LOCAL_MODE)"
log "Mode: $MODE"
log "Chat bridge: $CHAT_BRIDGE"
log "Data Machine: $INSTALL_DATA_MACHINE"
log "Multisite: $MULTISITE ($MULTISITE_TYPE)"
if [ "$DRY_RUN" = true ]; then
  log "Dry-run mode: commands will be printed, not executed"
fi

# ============================================================================
# Detect PHP Version
# ============================================================================

detect_php_version() {
  if command -v php &> /dev/null; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    log "Detected existing PHP version: $PHP_VERSION"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    PHP_VERSION="8.3"
    log "PHP version (dry-run assumed): $PHP_VERSION"
    return
  fi

  # apt-based detection only on Linux
  if [ "$PLATFORM" != "mac" ]; then
    apt update -qq 2>/dev/null
    PHP_VERSION=$(apt-cache search '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | \
      sed -E 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/' | \
      sort -t. -k1,1nr -k2,2nr | \
      head -1)
  fi

  if [ -n "$PHP_VERSION" ]; then
    log "Best available PHP version: $PHP_VERSION"
  else
    PHP_VERSION=""
    warn "Could not detect PHP version, will use system default"
  fi
}

detect_php_version

# ============================================================================
# Configuration
# ============================================================================

if [ "$MODE" = "existing" ]; then
  if [ -z "$EXISTING_WP" ]; then
    error "EXISTING_WP must be set when using --existing mode"
  fi
  if [ "$DRY_RUN" = false ] && [ ! -f "$EXISTING_WP/wp-config.php" ]; then
    error "No wp-config.php found at $EXISTING_WP"
  fi
  SITE_PATH="$EXISTING_WP"
  if [ "$DRY_RUN" = true ]; then
    SITE_DOMAIN="${SITE_DOMAIN:-$(basename "$SITE_PATH")}"
  else
    SITE_DOMAIN=$(cd "$SITE_PATH" && $WP_CMD option get siteurl $WP_ROOT_FLAG 2>/dev/null | sed 's|https\?://||' || basename "$SITE_PATH")
  fi
  log "Existing WordPress at: $SITE_PATH ($SITE_DOMAIN)"

  # Detect if existing WP is multisite
  if [ "$DRY_RUN" = false ]; then
    IS_EXISTING_MULTISITE=$(cd "$SITE_PATH" && $WP_CMD eval 'echo is_multisite() ? "yes" : "no";' $WP_ROOT_FLAG 2>/dev/null || echo "no")
    if [ "$IS_EXISTING_MULTISITE" = "yes" ]; then
      MULTISITE=true
      IS_SUBDOMAIN=$(cd "$SITE_PATH" && $WP_CMD eval 'echo is_subdomain_install() ? "yes" : "no";' $WP_ROOT_FLAG 2>/dev/null || echo "no")
      if [ "$IS_SUBDOMAIN" = "yes" ]; then
        MULTISITE_TYPE="subdomain"
      fi
      log "Detected existing multisite ($MULTISITE_TYPE)"
    fi
  fi
else
  SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
  SITE_PATH="${SITE_PATH:-/var/www/$SITE_DOMAIN}"
fi

DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wordpress}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 16)}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_PASS="${WP_ADMIN_PASS:-$(openssl rand -base64 16)}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@$SITE_DOMAIN}"
# Model defaults are empty — OpenCode uses its own zen free models by default.
# Set these env vars to override (e.g., OPENCODE_MODEL=anthropic/claude-sonnet-4-20250514)
OPENCODE_MODEL="${OPENCODE_MODEL:-}"
OPENCODE_SMALL_MODEL="${OPENCODE_SMALL_MODEL:-}"

# Service user configuration
if [ "$LOCAL_MODE" = true ]; then
  SERVICE_USER="$(whoami)"
  SERVICE_HOME="$HOME"
  KIMAKI_DATA_DIR="$HOME/.kimaki"
  DM_WORKSPACE_DIR="${DATAMACHINE_WORKSPACE_PATH:-$HOME/.datamachine/workspace}"
elif [ "$RUN_AS_ROOT" = true ]; then
  SERVICE_USER="root"
  SERVICE_HOME="/root"
  KIMAKI_DATA_DIR="/root/.kimaki"
  DM_WORKSPACE_DIR="${DATAMACHINE_WORKSPACE_PATH:-/var/lib/datamachine/workspace}"
else
  SERVICE_USER="opencode"
  SERVICE_HOME="/home/opencode"
  KIMAKI_DATA_DIR="/home/opencode/.kimaki"
  DM_WORKSPACE_DIR="${DATAMACHINE_WORKSPACE_PATH:-/var/lib/datamachine/workspace}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# --skills-only: skip everything except Phase 8.5
# ============================================================================

if [ "$SKILLS_ONLY" = true ]; then
  if [ -z "$SITE_PATH" ] && [ -z "$EXISTING_WP" ]; then
    error "SITE_PATH or EXISTING_WP must be set with --skills-only (e.g. SITE_PATH=/var/www/mysite ./setup.sh --skills-only)"
  fi
  SITE_PATH="${SITE_PATH:-$EXISTING_WP}"
  if [ "$DRY_RUN" = false ] && [ ! -d "$SITE_PATH" ]; then
    error "Directory not found: $SITE_PATH"
  fi
  # Auto-detect Data Machine if present
  if [ -d "$SITE_PATH/wp-content/plugins/data-machine" ]; then
    INSTALL_DATA_MACHINE=true
  fi
  log "Installing skills to $SITE_PATH/.opencode/skills/ ..."
fi

# ============================================================================
# Phases 1-8 (skipped by --skills-only)
# ============================================================================

if [ "$SKILLS_ONLY" != true ]; then

# ============================================================================
# Phase 1: System Dependencies
# ============================================================================

if [ "$SKIP_DEPS" = false ]; then
  log "Phase 1: Installing system dependencies..."
  run_cmd apt update
  run_cmd apt upgrade -y

  if [ -n "$PHP_VERSION" ]; then
    PHP_PACKAGES="php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-mbstring php${PHP_VERSION}-zip php${PHP_VERSION}-gd php${PHP_VERSION}-intl php${PHP_VERSION}-imagick"
  else
    PHP_PACKAGES="php-fpm php-mysql php-xml php-curl php-mbstring php-zip php-gd php-intl php-imagick"
  fi

  run_cmd apt install -y nginx $PHP_PACKAGES mariadb-server git unzip curl wget composer

  if [ -z "$PHP_VERSION" ] && command -v php &> /dev/null; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    log "PHP version after install: $PHP_VERSION"
  fi

  # Node.js
  if ! command -v node &> /dev/null || [ "$DRY_RUN" = true ]; then
    log "Installing Node.js..."
    if [ -z "$NODE_VERSION" ]; then
      NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | \
        grep -o '"version":"v[0-9]*' | head -1 | sed 's/"version":"v//')
      NODE_VERSION="${NODE_VERSION:-22}"
    fi
    log "Installing Node.js $NODE_VERSION..."
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"
      echo -e "${BLUE}[dry-run]${NC} apt install -y nodejs"
    else
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
      apt install -y nodejs
    fi
  else
    log "Node.js already installed: $(node --version)"
  fi

  # WP-CLI
  if ! command -v wp &> /dev/null || [ "$DRY_RUN" = true ]; then
    log "Installing WP-CLI..."
    run_cmd curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    run_cmd chmod +x wp-cli.phar
    run_cmd mv wp-cli.phar /usr/local/bin/wp
  fi
else
  log "Skipping system dependencies (--skip-deps)"
fi

# ============================================================================
# Phase 2: Database (fresh install only)
# ============================================================================

if [ "$MODE" = "fresh" ]; then
  log "Phase 2: Configuring database..."
  run_cmd mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
  run_cmd mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
  run_cmd mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
  run_cmd mysql -e "FLUSH PRIVILEGES;"
else
  log "Phase 2: Using existing database"
fi

# ============================================================================
# Phase 3: WordPress (fresh install only)
# ============================================================================

if [ "$MODE" = "fresh" ]; then
  log "Phase 3: Installing WordPress..."
  run_cmd mkdir -p "$SITE_PATH"
  if [ "$DRY_RUN" = false ]; then
    cd "$SITE_PATH"
  fi

  if [ ! -f wp-config.php ] || [ "$DRY_RUN" = true ]; then
    run_cmd $WP_CMD core download --allow-root
    run_cmd $WP_CMD config create --allow-root \
      --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost="localhost"
    run_cmd $WP_CMD core install --allow-root \
      --url="https://$SITE_DOMAIN" --title="My Site" \
      --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" \
      --admin_email="$WP_ADMIN_EMAIL"
  fi
  run_cmd chown -R www-data:www-data "$SITE_PATH"
else
  log "Phase 3: Using existing WordPress at $SITE_PATH"
  if [ "$DRY_RUN" = false ]; then
    cd "$SITE_PATH"
  fi
fi

# ============================================================================
# Phase 3.5: WordPress Multisite (optional)
# ============================================================================

if [ "$MULTISITE" = true ] && [ "$MODE" = "fresh" ]; then
  log "Phase 3.5: Converting to WordPress Multisite ($MULTISITE_TYPE)..."

  if [ "$MULTISITE_TYPE" = "subdomain" ]; then
    run_cmd $WP_CMD core multisite-convert --subdomains --allow-root --path="$SITE_PATH"
  else
    run_cmd $WP_CMD core multisite-convert --allow-root --path="$SITE_PATH"
  fi

  log "Multisite conversion complete"
elif [ "$MULTISITE" = true ] && [ "$MODE" = "existing" ]; then
  log "Phase 3.5: Existing multisite detected — skipping conversion"
fi

# ============================================================================
# Phase 3.9: Service User (early creation)
# ============================================================================
# Create the service user early so subsequent phases can chown to it.
# Phase 6 handles permissions and is idempotent (detects existing user).

if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
  if ! id -u "$SERVICE_USER" &>/dev/null || [ "$DRY_RUN" = true ]; then
    log "Phase 3.9: Creating service user '$SERVICE_USER'..."
    run_cmd useradd -m -s /bin/bash -G www-data "$SERVICE_USER"
  fi
fi

# ============================================================================
# Phase 4: Data Machine Plugin (optional)
# ============================================================================

if [ "$INSTALL_DATA_MACHINE" = true ]; then
  log "Phase 4: Installing Data Machine..."
  install_plugin data-machine https://github.com/Extra-Chill/data-machine.git

  if [ "$MULTISITE" = true ]; then
    log "Data Machine activated on main site. Activate on subsites with:"
    log "  $WP_CMD plugin activate data-machine --url=subsite.$SITE_DOMAIN $WP_ROOT_FLAG"
  fi

  log "Installing Data Machine Code (developer tools)..."
  install_plugin data-machine-code https://github.com/Extra-Chill/data-machine-code.git

  # Set workspace path in wp-config.php if not already defined.
  # On macOS the default /var/lib/datamachine/workspace isn't writable,
  # so data-machine-code's Workspace class resolves to empty string without this.
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    if ! grep -q 'DATAMACHINE_WORKSPACE_PATH' "$SITE_PATH/wp-config.php"; then
      wp_cmd config set DATAMACHINE_WORKSPACE_PATH "$DM_WORKSPACE_DIR" --type=constant
      log "Set DATAMACHINE_WORKSPACE_PATH to $DM_WORKSPACE_DIR"
    else
      log "DATAMACHINE_WORKSPACE_PATH already defined in wp-config.php"
    fi
  elif [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD config set DATAMACHINE_WORKSPACE_PATH $DM_WORKSPACE_DIR --type=constant"
  fi
else
  log "Phase 4: Skipping Data Machine (--no-data-machine)"
fi

# ============================================================================
# Phase 4.5: Create Data Machine Agent
# ============================================================================
# Data Machine needs an agent record so that `agent paths` returns valid paths
# and the agent boots with identity (SOUL.md) and memory (MEMORY.md) files.
# SITE.md is auto-generated by DM — no action needed.
# USER.md is user-scoped and left for later setup.

if [ "$INSTALL_DATA_MACHINE" = true ]; then
  log "Phase 4.5: Creating Data Machine agent..."

  # Derive agent slug from domain (or use AGENT_SLUG env var override):
  #   cluckinchuck.saraichinwag.com → cluckinchuck
  #   my-cool-site.com              → my-cool-site
  #   sub.domain.example.org        → sub
  if [ -z "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG=$(echo "$SITE_DOMAIN" | sed 's/\..*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  fi

  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    # Get site title for the agent display name
    # shellcheck disable=SC2086
    AGENT_NAME=$($WP_CMD option get blogname $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || echo "$AGENT_SLUG")

    # Check if agent already exists (idempotent for re-runs)
    # shellcheck disable=SC2086
    EXISTING_AGENT=$($WP_CMD datamachine agents show "$AGENT_SLUG" --format=json $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || echo "")

    if [ -z "$EXISTING_AGENT" ]; then
      log "Creating agent: $AGENT_SLUG ($AGENT_NAME)"
      wp_cmd datamachine agents create "$AGENT_SLUG" \
        --name="$AGENT_NAME" \
        --owner=1

      # Scaffold SOUL.md — basic identity template
      log "Scaffolding SOUL.md..."
      SOUL_CONTENT="# Agent Soul — ${AGENT_SLUG}

## Identity
I am ${AGENT_SLUG} — an AI agent managing ${AGENT_NAME} (${SITE_DOMAIN}). I operate on this WordPress site via WP-CLI and Data Machine.

## Voice & Tone
Be genuinely helpful. Skip filler. Be resourceful — read the file, check the context, search for it, then ask if stuck.

## Rules
- Private things stay private
- When in doubt, ask before acting externally
- Git for everything — no uncommitted work
- Root cause over symptoms — fix the real problem
- Stop when stuck — pause after 2-3 failures, ask for guidance
- NEVER deploy without being told to

## Context
I manage ${SITE_DOMAIN} — a WordPress site with Data Machine for persistent memory, scheduling, and AI tools."

      # shellcheck disable=SC2086
      echo "$SOUL_CONTENT" | $WP_CMD datamachine agent files write SOUL.md \
        --agent="$AGENT_SLUG" $WP_ROOT_FLAG --path="$SITE_PATH"

      # Scaffold MEMORY.md — empty starter
      log "Scaffolding MEMORY.md..."
      MEMORY_CONTENT="# Agent Memory — ${AGENT_SLUG}

## Operational Notes
- Agent created during wp-opencode setup on $(date +%Y-%m-%d)"

      # shellcheck disable=SC2086
      echo "$MEMORY_CONTENT" | $WP_CMD datamachine agent files write MEMORY.md \
        --agent="$AGENT_SLUG" $WP_ROOT_FLAG --path="$SITE_PATH"

      log "Agent '$AGENT_SLUG' created with SOUL.md and MEMORY.md"
    else
      log "Agent '$AGENT_SLUG' already exists — skipping creation"
    fi
  else
    log "Dry-run: would create agent '$AGENT_SLUG' with SOUL.md and MEMORY.md"
  fi
else
  AGENT_SLUG=""
fi

# ============================================================================
# Phase 4.6: Extra Plugins (caller-provided)
# ============================================================================

if [ -n "${EXTRA_PLUGINS:-}" ]; then
  log "Phase 4.6: Installing extra plugins..."
  for entry in $EXTRA_PLUGINS; do
    slug="${entry%%:*}"
    url="${entry#*:}"
    if [ -z "$slug" ] || [ -z "$url" ]; then
      warn "Skipping malformed EXTRA_PLUGINS entry: $entry"
      continue
    fi
    install_plugin "$slug" "$url"
  done
fi

# ============================================================================
# Phase 5: Nginx (fresh install only)
# ============================================================================

if [ "$MODE" = "fresh" ]; then
  log "Phase 5: Configuring nginx..."

  if [ -n "$PHP_VERSION" ]; then
    PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
  else
    if [ "$DRY_RUN" = false ]; then
      PHP_FPM_SOCK=$(find /var/run/php -name "php*-fpm.sock" 2>/dev/null | head -1)
    fi
    PHP_FPM_SOCK="${PHP_FPM_SOCK:-/var/run/php/php-fpm.sock}"
  fi

  if [ "$MULTISITE" = true ] && [ "$MULTISITE_TYPE" = "subdomain" ]; then
    NGINX_CONFIG="server {
    listen 80;
    server_name $SITE_DOMAIN *.$SITE_DOMAIN;
    root $SITE_PATH;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
    }

    location ~ /\\.ht {
        deny all;
    }

    location ~ ^/files/(.*)$ {
        try_files /wp-includes/ms-files.php?\$args =404;
        access_log off;
        log_not_found off;
        expires max;
    }
}"
  elif [ "$MULTISITE" = true ] && [ "$MULTISITE_TYPE" = "subdirectory" ]; then
    NGINX_CONFIG="server {
    listen 80;
    server_name $SITE_DOMAIN www.$SITE_DOMAIN;
    root $SITE_PATH;
    index index.php index.html;

    if (!-e \$request_filename) {
        rewrite /wp-admin\$ \$scheme://\$host\$request_uri/ permanent;
        rewrite ^(/[^/]+)?(/wp-.*) \$2 last;
        rewrite ^(/[^/]+)?(/.*\\.php) \$2 last;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
    }

    location ~ /\\.ht {
        deny all;
    }

    location ~ ^/[_0-9a-zA-Z-]+/files/(.*)$ {
        try_files /wp-includes/ms-files.php?\$args =404;
        access_log off;
        log_not_found off;
        expires max;
    }
}"
  else
    NGINX_CONFIG="server {
    listen 80;
    server_name $SITE_DOMAIN www.$SITE_DOMAIN;
    root $SITE_PATH;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
    }

    location ~ /\\.ht {
        deny all;
    }
}"
  fi

  write_file "/etc/nginx/sites-available/$SITE_DOMAIN" "$NGINX_CONFIG"
  run_cmd ln -sf "/etc/nginx/sites-available/$SITE_DOMAIN" /etc/nginx/sites-enabled/

  if [ "$DRY_RUN" = false ]; then
    nginx -t && systemctl reload nginx
  fi
  run_cmd systemctl enable nginx
  if [ -n "$PHP_VERSION" ]; then
    run_cmd systemctl enable "php${PHP_VERSION}-fpm"
  fi
else
  log "Phase 5: Using existing nginx configuration"
fi

# ============================================================================
# Phase 5.5: SSL (Let's Encrypt)
# ============================================================================

if [ "$SKIP_SSL" = true ]; then
  log "Skipping SSL (--skip-ssl)"
else
  log "Phase 5.5: Configuring SSL..."

  if ! command -v certbot &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd apt install -y certbot python3-certbot-nginx
  fi

  if [ "$DRY_RUN" = false ]; then
    SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null)
    DOMAIN_IP=$(dig +short "$SITE_DOMAIN" A 2>/dev/null | head -1)

    if [ "$SERVER_IP" = "$DOMAIN_IP" ]; then
      log "DNS verified. Running certbot..."

      if [ "$MULTISITE" = true ] && [ "$MULTISITE_TYPE" = "subdomain" ]; then
        warn "Subdomain multisite requires a wildcard SSL certificate (*.$SITE_DOMAIN)"
        warn "Wildcard certs require DNS validation. Install a certbot DNS plugin:"
        warn "  apt install python3-certbot-dns-cloudflare  # (or your DNS provider)"
        warn "Then run: certbot certonly --dns-cloudflare -d $SITE_DOMAIN -d '*.$SITE_DOMAIN'"
        warn "Installing cert for main domain only..."
        if certbot --nginx -d "$SITE_DOMAIN" --non-interactive --agree-tos \
            --email "$WP_ADMIN_EMAIL" --redirect; then
          log "SSL installed for main domain. Wildcard cert needed for subdomain sites."
        else
          warn "Certbot failed. Run manually: certbot --nginx -d $SITE_DOMAIN"
        fi
      else
        if certbot --nginx -d "$SITE_DOMAIN" --non-interactive --agree-tos \
            --email "$WP_ADMIN_EMAIL" --redirect; then
          log "SSL certificate installed!"
        else
          warn "Certbot failed. Run manually: certbot --nginx -d $SITE_DOMAIN"
        fi
      fi
    else
      warn "DNS not pointing here yet (expected $SERVER_IP, got $DOMAIN_IP)"
      if [ "$MULTISITE" = true ] && [ "$MULTISITE_TYPE" = "subdomain" ]; then
        warn "Run later: certbot certonly --dns-<provider> -d $SITE_DOMAIN -d '*.$SITE_DOMAIN'"
      else
        warn "Run later: certbot --nginx -d $SITE_DOMAIN"
      fi
    fi
  fi
fi

# ============================================================================
# Phase 6: Service User Permissions
# ============================================================================
# User was created in Phase 3.9. This phase handles file permissions.

if [ "$LOCAL_MODE" = true ]; then
  log "Phase 6: Local mode — skipping service user setup"
elif [ "$RUN_AS_ROOT" = false ]; then
  log "Phase 6: Configuring service user permissions..."

  if ! id -u "$SERVICE_USER" &>/dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd useradd -m -s /bin/bash -G www-data "$SERVICE_USER"
  else
    log "User '$SERVICE_USER' already exists"
    run_cmd usermod -a -G www-data "$SERVICE_USER"
  fi

  # WordPress files need to be group-writable for the agent
  run_cmd chmod -R g+w "$SITE_PATH"
  run_cmd chown -R www-data:www-data "$SITE_PATH"

  # Create kimaki data directory
  run_cmd mkdir -p "$KIMAKI_DATA_DIR"
  run_cmd chown -R "$SERVICE_USER:$SERVICE_USER" "$KIMAKI_DATA_DIR"
else
  log "Phase 6: Running as root (--root)"
  run_cmd mkdir -p "$KIMAKI_DATA_DIR"
fi

# ============================================================================
# Phase 7: OpenCode
# ============================================================================

log "Phase 7: Installing OpenCode..."

if ! command -v opencode &> /dev/null || [ "$DRY_RUN" = true ]; then
  run_cmd npm install -g opencode-ai
else
  log "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'unknown')"
fi

# Generate opencode.json (skip if already exists — safe for re-runs)
if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/opencode.json" ]; then
  log "opencode.json already exists — skipping (delete to regenerate)"
else
log "Generating opencode.json..."

if [ "$INSTALL_DATA_MACHINE" = true ]; then
  # Discover agent file paths via Data Machine CLI (layered architecture).
  # Phase 4.5 created the agent and scaffolded files, so paths resolve correctly.
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_FLAG=""
    if [ -n "$AGENT_SLUG" ]; then
      AGENT_FLAG="--agent=$AGENT_SLUG"
    fi
    DM_PATHS_RAW=$($WP_CMD datamachine agent paths --format=json $AGENT_FLAG $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null)
    # SQLite translation layer may emit HTML error noise to stdout — extract only the JSON object
    DM_PATHS_JSON=$(echo "$DM_PATHS_RAW" | sed -n '/^{/,/^}/p')
    if [ -z "$DM_PATHS_JSON" ]; then
      error "'$WP_CMD datamachine agent paths' returned no JSON — is Data Machine active and agent created?"
    fi
    # Extract relative_files array from JSON — these are the correct layered paths
    DM_AGENT_FILES=$(echo "$DM_PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
")
    log "Agent files discovered via '$WP_CMD datamachine agent paths${AGENT_FLAG:+ ($AGENT_FLAG)}'"
  else
    # Dry-run: can't query WP, use placeholder paths with derived slug
    DM_DRY_SLUG="${AGENT_SLUG:-AGENT_SLUG}"
    DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/SOUL.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/MEMORY.md
wp-content/uploads/datamachine-files/users/USER_ID/USER.md"
    log "Dry-run: using placeholder agent paths (slug: $DM_DRY_SLUG)"
  fi

  # Build prompt from discovered files (layered: SITE.md → SOUL.md → MEMORY.md → USER.md)
  OPENCODE_PROMPT="{file:./AGENTS.md}"
  while IFS= read -r rel_path; do
    OPENCODE_PROMPT="$OPENCODE_PROMPT\\\\n{file:./${rel_path}}"
  done <<< "$DM_AGENT_FILES"
else
  # Without Data Machine: just AGENTS.md
  OPENCODE_PROMPT='{file:./AGENTS.md}'
fi

# Build opencode.json — only include model fields if explicitly set
OPENCODE_JSON="{"
OPENCODE_JSON="$OPENCODE_JSON\n  \"\$schema\": \"https://opencode.ai/config.json\""

if [ -n "$OPENCODE_MODEL" ]; then
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"model\": \"${OPENCODE_MODEL}\""
fi
if [ -n "$OPENCODE_SMALL_MODEL" ]; then
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"small_model\": \"${OPENCODE_SMALL_MODEL}\""
fi

# OpenCode plugins — only when DM handles memory/scheduling via Kimaki
if [ "$INSTALL_DATA_MACHINE" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
  # dm-context-filter: strips redundant Kimaki context when DM manages it
  # dm-agent-sync: dynamically registers all DM agents in the agent switcher
  if [ "$LOCAL_MODE" = true ]; then
    KIMAKI_PLUGINS_DIR="$(npm root -g 2>/dev/null)/kimaki/plugins"
    # Copy plugins from wp-opencode repo to Kimaki's npm directory
    if [ "$DRY_RUN" = false ] && [ -d "$(dirname "$KIMAKI_PLUGINS_DIR")" ]; then
      mkdir -p "$KIMAKI_PLUGINS_DIR"
      cp "$SCRIPT_DIR/kimaki/plugins/dm-context-filter.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
      cp "$SCRIPT_DIR/kimaki/plugins/dm-agent-sync.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
    fi
  else
    KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
  fi
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"plugin\": ["
  OPENCODE_JSON="$OPENCODE_JSON\n    \"${KIMAKI_PLUGINS_DIR}/dm-context-filter.ts\","
  OPENCODE_JSON="$OPENCODE_JSON\n    \"${KIMAKI_PLUGINS_DIR}/dm-agent-sync.ts\""
  OPENCODE_JSON="$OPENCODE_JSON\n  ]"
fi

# Agent prompt config — always include so DM memory files are injected.
# The dm-agent-sync plugin will discover additional agents at runtime and
# register them in the agent switcher. This static config provides the
# initial/default agent for build and plan modes.
OPENCODE_JSON="$OPENCODE_JSON,\n  \"agent\": {"
OPENCODE_JSON="$OPENCODE_JSON\n    \"build\": {"
OPENCODE_JSON="$OPENCODE_JSON\n      \"prompt\": \"${OPENCODE_PROMPT}\""
OPENCODE_JSON="$OPENCODE_JSON\n    },"
OPENCODE_JSON="$OPENCODE_JSON\n    \"plan\": {"
OPENCODE_JSON="$OPENCODE_JSON\n      \"prompt\": \"${OPENCODE_PROMPT}\""
OPENCODE_JSON="$OPENCODE_JSON\n    }"
OPENCODE_JSON="$OPENCODE_JSON\n  }"

# Permission: allow Data Machine Code workspace as external directory.
# data-machine-code creates the workspace directory lazily on first use.
# OpenCode still needs an allowlist entry to access paths outside the project root.
if [ "$INSTALL_DATA_MACHINE" = true ]; then
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"permission\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"external_directory\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"${DM_WORKSPACE_DIR}/**\": \"allow\""
  OPENCODE_JSON="$OPENCODE_JSON\n    }"
  OPENCODE_JSON="$OPENCODE_JSON\n  }"
fi

OPENCODE_JSON="$OPENCODE_JSON\n}"

if [ "$DRY_RUN" = true ]; then
  echo -e "${BLUE}[dry-run]${NC} Would write to $SITE_PATH/opencode.json"
else
  echo -e "$OPENCODE_JSON" > "$SITE_PATH/opencode.json"
fi

# End opencode.json existence guard
fi

# Merge caller-provided MCP servers (always runs — additive to existing file)
if [ -n "${MCP_SERVERS:-}" ] && [ -f "$SITE_PATH/opencode.json" ]; then
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge MCP_SERVERS into opencode.json"
  else
    command -v jq &>/dev/null || error "MCP_SERVERS requires jq"
    log "Merging MCP servers into opencode.json..."
    jq --argjson mcp "$MCP_SERVERS" '.mcp = $mcp' "$SITE_PATH/opencode.json" \
      > "$SITE_PATH/opencode.json.tmp" \
      && mv "$SITE_PATH/opencode.json.tmp" "$SITE_PATH/opencode.json"
  fi
fi

# ============================================================================
# Phase 8: AGENTS.md
# ============================================================================

# Generate AGENTS.md (skip if already exists — may have been customized)
if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
  log "Phase 8: AGENTS.md already exists — skipping (delete to regenerate)"
else
  log "Phase 8: Generating AGENTS.md..."

  if [ -f "$SCRIPT_DIR/workspace/AGENTS.md" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would generate AGENTS.md from template"
    else
      sed -e "s|{{SITE_PATH}}|$SITE_PATH|g" -e "s|{{WP_FLAGS}}|$WP_ROOT_FLAG|g" "$SCRIPT_DIR/workspace/AGENTS.md" > "$SITE_PATH/AGENTS.md"
    fi
  else
    # Inline fallback if template not available
    write_file "$SITE_PATH/AGENTS.md" "# AGENTS.md

## WordPress Environment
Site root: \`$SITE_PATH\`
WP-CLI: \`$WP_CMD $WP_ROOT_FLAG --path=$SITE_PATH\`

## Safety
- Don't leak private data
- Don't run destructive commands without asking
- When in doubt, ask
"
  fi

  # Remove Data Machine sections if DM not installed
  if [ "$INSTALL_DATA_MACHINE" = false ]; then
    if [ -f "$SITE_PATH/AGENTS.md" ]; then
      log "Removing Data Machine references from AGENTS.md..."
      # Strip ### Data Machine and ### Workspace (both are DM features)
      awk '/^### (Data Machine|Workspace)/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip' \
        "$SITE_PATH/AGENTS.md" > "$SITE_PATH/AGENTS.md.tmp" 2>/dev/null || true
      mv "$SITE_PATH/AGENTS.md.tmp" "$SITE_PATH/AGENTS.md"
    fi
  fi

  # Remove multisite section for single-site installs
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
    IS_MULTISITE="${IS_MULTISITE:-no}"
    if [ "$IS_MULTISITE" != "yes" ]; then
      awk '/^### Multisite/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip' \
        "$SITE_PATH/AGENTS.md" > "$SITE_PATH/AGENTS.md.tmp" 2>/dev/null || true
      mv "$SITE_PATH/AGENTS.md.tmp" "$SITE_PATH/AGENTS.md"
    fi
  fi
fi

# Copy BOOTSTRAP.md if not already present
if [ -f "$SCRIPT_DIR/workspace/BOOTSTRAP.md" ] && [ ! -f "$SITE_PATH/BOOTSTRAP.md" ]; then
  run_cmd cp "$SCRIPT_DIR/workspace/BOOTSTRAP.md" "$SITE_PATH/BOOTSTRAP.md"
elif [ -f "$SITE_PATH/BOOTSTRAP.md" ]; then
  log "BOOTSTRAP.md already exists — skipping"
fi

# End of --skills-only guard (Phases 1-8)
fi

# ============================================================================
# Phase 8.5: Skills
# ============================================================================

SKILLS_DIR="$SITE_PATH/.opencode/skills"

if [ "$INSTALL_SKILLS" = true ]; then
  log "Phase 8.5: Installing agent skills..."
  run_cmd mkdir -p "$SKILLS_DIR"

  install_skills_from_repo "https://github.com/WordPress/agent-skills.git" "WordPress agent skills"

  if [ "$INSTALL_DATA_MACHINE" = true ]; then
    install_skills_from_repo "https://github.com/Extra-Chill/data-machine-skills.git" "Data Machine skills"
  fi

  # Note: wp-opencode-setup skill is NOT deployed to the VPS.
  # It's for local agents helping users run setup.sh over SSH.

  # Also copy skills to Kimaki's directory if Kimaki is the chat bridge.
  # Kimaki overrides OpenCode's skill discovery paths to only look in its
  # own bundled skills dir, so .opencode/skills/ alone isn't enough.
  if [ "$DRY_RUN" = true ]; then
    KIMAKI_SKILLS_DIR="/usr/lib/node_modules/kimaki/skills"
    echo -e "${BLUE}[dry-run]${NC} Would copy skills to $KIMAKI_SKILLS_DIR/ (if Kimaki installed)"
  elif command -v kimaki &> /dev/null; then
    KIMAKI_SKILLS_DIR="$(npm root -g 2>/dev/null)/kimaki/skills"
    if [ -d "$KIMAKI_SKILLS_DIR" ]; then
      for skill_dir in "$SKILLS_DIR"/*/; do
        skill_name=$(basename "$skill_dir")
        if [ -f "$skill_dir/SKILL.md" ]; then
          cp -r "$skill_dir" "$KIMAKI_SKILLS_DIR/$skill_name"
        fi
      done
      log "Skills also copied to Kimaki: $KIMAKI_SKILLS_DIR/"
      warn "Note: Kimaki upgrades (npm update -g kimaki) will remove these. Re-run --skills-only after upgrading."
    fi
  fi
else
  log "Phase 8.5: Skipping agent skills (--no-skills)"
fi

# --skills-only: done, exit early
if [ "$SKILLS_ONLY" = true ]; then
  echo ""
  log "Skills installed to $SKILLS_DIR/"
  if [ "$DRY_RUN" = false ]; then
    ls -1 "$SKILLS_DIR" 2>/dev/null | while read -r skill; do
      log "  - $skill"
    done
  fi
  exit 0
fi

# ============================================================================
# Phase 9: Chat Bridge
# ============================================================================

if [ "$INSTALL_CHAT" = true ]; then
  log "Phase 9: Installing chat bridge ($CHAT_BRIDGE)..."

  case "$CHAT_BRIDGE" in
    kimaki)
      if ! command -v kimaki &> /dev/null || [ "$DRY_RUN" = true ]; then
        run_cmd npm install -g kimaki
      else
        log "Kimaki already installed: $(kimaki --version 2>/dev/null | head -1)"
      fi

      if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
        # macOS: create a launchd plist for persistent Kimaki service
        KIMAKI_PLIST_LABEL="com.extrachill.kimaki"
        KIMAKI_PLIST_DIR="$HOME/Library/LaunchAgents"
        KIMAKI_PLIST="$KIMAKI_PLIST_DIR/$KIMAKI_PLIST_LABEL.plist"

        if [ "$DRY_RUN" = true ]; then
          KIMAKI_BIN="/opt/homebrew/bin/kimaki"
        else
          KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/opt/homebrew/bin/kimaki")
        fi

        run_cmd mkdir -p "$KIMAKI_DATA_DIR"
        run_cmd mkdir -p "$KIMAKI_PLIST_DIR"

        KIMAKI_PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>$KIMAKI_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$KIMAKI_BIN</string>
        <string>--data-dir</string>
        <string>$KIMAKI_DATA_DIR</string>
        <string>--auto-restart</string>
        <string>--no-critique</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$KIMAKI_DATA_DIR/kimaki.log</string>
    <key>StandardErrorPath</key>
    <string>$KIMAKI_DATA_DIR/kimaki.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>KIMAKI_DATA_DIR</key>
        <string>$KIMAKI_DATA_DIR</string>$(if [ -n "$KIMAKI_BOT_TOKEN" ]; then echo "
        <key>KIMAKI_BOT_TOKEN</key>
        <string>$KIMAKI_BOT_TOKEN</string>"; fi)
    </dict>
</dict>
</plist>"

        write_file "$KIMAKI_PLIST" "$KIMAKI_PLIST_CONTENT"

        if [ "$DRY_RUN" = false ] && [ -n "$KIMAKI_BOT_TOKEN" ]; then
          launchctl bootout "gui/$(id -u)" "$KIMAKI_PLIST" 2>/dev/null || true
          launchctl bootstrap "gui/$(id -u)" "$KIMAKI_PLIST"
          log "Kimaki launchd service installed and started"
        elif [ "$DRY_RUN" = false ]; then
          log "KIMAKI_BOT_TOKEN not set — service not started"
          log "Run onboarding first, then enable the service:"
          log "  cd $SITE_PATH && kimaki"
          log "  launchctl bootstrap gui/$(id -u) $KIMAKI_PLIST"
        fi

        log "Kimaki service: $KIMAKI_PLIST_LABEL"
        log "  Start:  launchctl kickstart gui/$(id -u)/$KIMAKI_PLIST_LABEL"
        log "  Stop:   launchctl kill SIGTERM gui/$(id -u)/$KIMAKI_PLIST_LABEL"
        log "  Logs:   tail -f $KIMAKI_DATA_DIR/kimaki.log"

      elif [ "$LOCAL_MODE" = true ]; then
        # Non-macOS local mode: no service manager, run manually
        log "Local mode: Kimaki installed. Run manually with:"
        log "  cd $SITE_PATH && kimaki"
      else
        # VPS mode: copy config and create systemd service
        KIMAKI_CONFIG_DIR="/opt/kimaki-config"
        run_cmd cp -r "$SCRIPT_DIR/kimaki" "$KIMAKI_CONFIG_DIR"
        run_cmd chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"

        # Build environment lines for systemd
        ENV_LINES="Environment=HOME=$SERVICE_HOME"
        ENV_LINES="$ENV_LINES\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin"
        ENV_LINES="$ENV_LINES\nEnvironment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"

        if [ -n "$KIMAKI_BOT_TOKEN" ]; then
          ENV_LINES="$ENV_LINES\nEnvironment=KIMAKI_BOT_TOKEN=$KIMAKI_BOT_TOKEN"
        fi

        # Find kimaki binary
        if [ "$DRY_RUN" = true ]; then
          KIMAKI_BIN="/usr/bin/kimaki"
        else
          KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/usr/bin/kimaki")
        fi

        SYSTEMD_CONFIG="[Unit]
Description=Kimaki Discord Bot (wp-opencode)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$(echo -e "$ENV_LINES")
ExecStartPre=$KIMAKI_CONFIG_DIR/post-upgrade.sh
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

        write_file "/etc/systemd/system/kimaki.service" "$SYSTEMD_CONFIG"
        run_cmd systemctl daemon-reload
        run_cmd systemctl enable kimaki
      fi
      ;;

    telegram)
      # Install @grinev/opencode-telegram-bot — richest feature set:
      # interactive Q&A, session management, model switching, file attachments
      if ! command -v opencode-telegram &> /dev/null || [ "$DRY_RUN" = true ]; then
        run_cmd npm install -g @grinev/opencode-telegram-bot
      else
        log "opencode-telegram already installed: $(opencode-telegram --version 2>/dev/null | head -1)"
      fi

      # Validate credentials early — warn if missing so user knows before service start
      if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        warn "TELEGRAM_BOT_TOKEN not set — service will fail to start until you add it."
        warn "  Edit $SERVICE_HOME/.config/opencode-telegram-bot/.env after setup."
      fi
      if [ -z "$TELEGRAM_ALLOWED_USER_ID" ]; then
        warn "TELEGRAM_ALLOWED_USER_ID not set — service will fail to start until you add it."
        warn "  Get your ID from @userinfobot on Telegram, then edit the .env file."
      fi

      # Find binaries (platform-aware dry-run defaults)
      if [ "$DRY_RUN" = true ]; then
        if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
          TELEGRAM_BIN="/opt/homebrew/bin/opencode-telegram"
          OPENCODE_BIN="/opt/homebrew/bin/opencode"
        else
          TELEGRAM_BIN="/usr/bin/opencode-telegram"
          OPENCODE_BIN="/usr/bin/opencode"
        fi
      else
        TELEGRAM_BIN=$(which opencode-telegram 2>/dev/null || echo "/usr/bin/opencode-telegram")
        OPENCODE_BIN=$(which opencode 2>/dev/null || echo "/usr/bin/opencode")
      fi

      # --- opencode-serve env file ---
      # Keeps model config out of the unit/plist. Written for all environments.
      SERVE_ENV_FILE="$SERVICE_HOME/.config/opencode-serve.env"
      run_cmd mkdir -p "$SERVICE_HOME/.config"
      if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would write opencode-serve config to $SERVE_ENV_FILE"
      else
        {
          [ -n "$OPENCODE_MODEL" ] && echo "OPENCODE_MODEL=$OPENCODE_MODEL"
          true  # ensure file is always created (may be empty if no overrides)
        } > "$SERVE_ENV_FILE"
        chmod 600 "$SERVE_ENV_FILE"
        if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
          chown "$SERVICE_USER:$SERVICE_USER" "$SERVE_ENV_FILE"
        fi
      fi

      # --- Telegram bot .env file (single source of truth for all app config) ---
      TELEGRAM_CONFIG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"
      run_cmd mkdir -p "$TELEGRAM_CONFIG_DIR"
      if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
        run_cmd chown -R "$SERVICE_USER:$SERVICE_USER" "$TELEGRAM_CONFIG_DIR"
      fi

      TELEGRAM_ENV_CONTENT="TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_ALLOWED_USER_ID=${TELEGRAM_ALLOWED_USER_ID:-}
OPENCODE_API_URL=http://localhost:4096
OPENCODE_MODEL_PROVIDER=${OPENCODE_MODEL_PROVIDER:-opencode}
OPENCODE_MODEL_ID=${OPENCODE_MODEL_ID:-big-pickle}
LOG_LEVEL=info"

      if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would write Telegram bot config to $TELEGRAM_CONFIG_DIR/.env"
      else
        echo "$TELEGRAM_ENV_CONTENT" > "$TELEGRAM_CONFIG_DIR/.env"
        chmod 600 "$TELEGRAM_CONFIG_DIR/.env"
        if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
          chown "$SERVICE_USER:$SERVICE_USER" "$TELEGRAM_CONFIG_DIR/.env"
        fi
      fi

      if [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
        # macOS: TWO launchd plists (opencode-serve + opencode-telegram)
        SERVE_PLIST_LABEL="com.extrachill.opencode-serve"
        TELEGRAM_PLIST_LABEL="com.extrachill.opencode-telegram"
        PLIST_DIR="$HOME/Library/LaunchAgents"
        SERVE_PLIST="$PLIST_DIR/$SERVE_PLIST_LABEL.plist"
        TELEGRAM_PLIST="$PLIST_DIR/$TELEGRAM_PLIST_LABEL.plist"
        TELEGRAM_LOG_DIR="$SERVICE_HOME/.config/opencode-telegram-bot"

        run_cmd mkdir -p "$PLIST_DIR"

        # --- com.extrachill.opencode-serve plist ---
        # launchd doesn't support EnvironmentFile, so model config is baked in
        SERVE_PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>$SERVE_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$OPENCODE_BIN</string>
        <string>serve</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$TELEGRAM_LOG_DIR/opencode-serve.log</string>
    <key>StandardErrorPath</key>
    <string>$TELEGRAM_LOG_DIR/opencode-serve.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>$(if [ -n "$OPENCODE_MODEL" ]; then echo "
        <key>OPENCODE_MODEL</key>
        <string>$OPENCODE_MODEL</string>"; fi)
    </dict>
</dict>
</plist>"

        write_file "$SERVE_PLIST" "$SERVE_PLIST_CONTENT"

        # --- com.extrachill.opencode-telegram plist ---
        # Tokens inlined since launchd doesn't support EnvironmentFile
        TELEGRAM_PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>$TELEGRAM_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TELEGRAM_BIN</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$TELEGRAM_LOG_DIR/opencode-telegram.log</string>
    <key>StandardErrorPath</key>
    <string>$TELEGRAM_LOG_DIR/opencode-telegram.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>$(if [ -n "$TELEGRAM_BOT_TOKEN" ]; then echo "
        <key>TELEGRAM_BOT_TOKEN</key>
        <string>$TELEGRAM_BOT_TOKEN</string>"; fi)$(if [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then echo "
        <key>TELEGRAM_ALLOWED_USER_ID</key>
        <string>$TELEGRAM_ALLOWED_USER_ID</string>"; fi)
        <key>OPENCODE_API_URL</key>
        <string>http://localhost:4096</string>
    </dict>
</dict>
</plist>"

        write_file "$TELEGRAM_PLIST" "$TELEGRAM_PLIST_CONTENT"

        # Bootstrap both if tokens are provided
        if [ "$DRY_RUN" = false ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
          launchctl bootout "gui/$(id -u)" "$SERVE_PLIST" 2>/dev/null || true
          launchctl bootstrap "gui/$(id -u)" "$SERVE_PLIST"
          launchctl bootout "gui/$(id -u)" "$TELEGRAM_PLIST" 2>/dev/null || true
          launchctl bootstrap "gui/$(id -u)" "$TELEGRAM_PLIST"
          log "Telegram bot launchd services installed and started"
        elif [ "$DRY_RUN" = false ]; then
          log "Telegram credentials not set — services not started"
          log "Add tokens to $TELEGRAM_CONFIG_DIR/.env, then re-run setup or bootstrap manually:"
          log "  launchctl bootstrap gui/$(id -u) $SERVE_PLIST"
          log "  launchctl bootstrap gui/$(id -u) $TELEGRAM_PLIST"
        fi

        log "OpenCode serve: $SERVE_PLIST_LABEL"
        log "Telegram bot:   $TELEGRAM_PLIST_LABEL"
        log "  Start:  launchctl kickstart gui/$(id -u)/$SERVE_PLIST_LABEL"
        log "          launchctl kickstart gui/$(id -u)/$TELEGRAM_PLIST_LABEL"
        log "  Stop:   launchctl kill SIGTERM gui/$(id -u)/$SERVE_PLIST_LABEL"
        log "          launchctl kill SIGTERM gui/$(id -u)/$TELEGRAM_PLIST_LABEL"
        log "  Logs:   tail -f $TELEGRAM_LOG_DIR/opencode-serve.log"
        log "          tail -f $TELEGRAM_LOG_DIR/opencode-telegram.log"

      elif [ "$LOCAL_MODE" = true ]; then
        # Non-macOS local: manual run instructions
        log "Local mode: Telegram bot installed. Run manually with:"
        log "  cd $SITE_PATH && opencode serve &"
        log "  opencode-telegram start"

      else
        # VPS: systemd services (opencode-serve + opencode-telegram)

        # --- opencode-serve.service ---
        # The Telegram bot connects to opencode's HTTP server (localhost:4096).
        # HOME and PATH are runtime environment, not config — inline is correct here.
        # Model config comes from EnvironmentFile so it never lives in a world-readable unit.
        OPENCODE_SERVE_CONFIG="[Unit]
Description=OpenCode Server (wp-opencode)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-$SERVE_ENV_FILE
ExecStart=$OPENCODE_BIN serve
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

        write_file "/etc/systemd/system/opencode-serve.service" "$OPENCODE_SERVE_CONFIG"
        run_cmd systemctl daemon-reload
        run_cmd systemctl enable opencode-serve

        # --- opencode-telegram.service ---
        # Secrets and app config come exclusively from EnvironmentFile.
        # HOME and PATH are runtime environment — inline is correct and not sensitive.
        TELEGRAM_SYSTEMD_CONFIG="[Unit]
Description=OpenCode Telegram Bot (wp-opencode)
After=network.target opencode-serve.service
Requires=opencode-serve.service

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$TELEGRAM_CONFIG_DIR/.env
ExecStart=$TELEGRAM_BIN start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

        write_file "/etc/systemd/system/opencode-telegram.service" "$TELEGRAM_SYSTEMD_CONFIG"
        run_cmd systemctl daemon-reload
        run_cmd systemctl enable opencode-telegram
      fi
      ;;

    *)
      warn "Unknown chat bridge: $CHAT_BRIDGE"
      warn "Supported bridges: kimaki, telegram"
      warn "Skipping chat bridge installation"
      ;;
  esac
else
  log "Phase 9: Skipping chat bridge (--no-chat)"
fi

# ============================================================================
# Done
# ============================================================================

echo ""
echo "=============================================="
if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}wp-opencode dry-run complete!${NC}"
  echo "(No changes were made)"
else
  echo -e "${GREEN}wp-opencode installation complete!${NC}"
fi
echo "=============================================="
echo ""
if [ "$LOCAL_MODE" = true ]; then
  echo "Platform:   Local ($OS)"
fi
echo "WordPress:"
echo "  URL:      https://$SITE_DOMAIN"
echo "  Admin:    https://$SITE_DOMAIN/wp-admin"
echo "  Path:     $SITE_PATH"
echo ""
echo "OpenCode:"
echo "  Config:   $SITE_PATH/opencode.json"
if [ -n "$OPENCODE_MODEL" ]; then
  echo "  Model:    $OPENCODE_MODEL"
else
  echo "  Model:    (OpenCode default — zen free models)"
fi
echo ""
if [ "$MULTISITE" = true ]; then
  echo "Multisite:"
  echo "  Type:        $MULTISITE_TYPE"
  echo ""
fi
if [ "$INSTALL_DATA_MACHINE" = true ]; then
  echo "Data Machine:"
  if [ -n "$AGENT_SLUG" ]; then
    echo "  Agent:       $AGENT_SLUG"
  fi
  echo "  Discover:    $WP_CMD datamachine agent paths${AGENT_SLUG:+ --agent=$AGENT_SLUG} $WP_ROOT_FLAG"
  echo "  Code tools:  data-machine-code (workspace, GitHub, git)"
  echo "  Workspace:   $DM_WORKSPACE_DIR (created on first use)"
  echo ""
fi
echo "Agent:"
if [ "$LOCAL_MODE" = true ]; then
  echo "  User:     $(whoami) (local)"
elif [ "$RUN_AS_ROOT" = true ]; then
  echo "  User:     root"
else
  echo "  User:     $SERVICE_USER (non-root)"
fi
if [ "$INSTALL_CHAT" = true ]; then
  echo "  Bridge:   $CHAT_BRIDGE"
fi
if [ "$INSTALL_SKILLS" = true ]; then
  echo "  Skills:   $SKILLS_DIR"
else
  echo "  Skills:   Skipped (--no-skills)"
fi
echo ""

# Save credentials (VPS only — local installs don't generate credentials)
if [ "$LOCAL_MODE" = false ]; then
  CREDENTIALS_CONTENT="# wp-opencode credentials (keep this secure!)
# Generated: $(date)

SITE_DOMAIN=$SITE_DOMAIN
SITE_PATH=$SITE_PATH
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_PASS=$WP_ADMIN_PASS
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DATA_MACHINE=$INSTALL_DATA_MACHINE
AGENT_SLUG=$AGENT_SLUG
MULTISITE=$MULTISITE
MULTISITE_TYPE=$MULTISITE_TYPE
SERVICE_USER=$SERVICE_USER
CHAT_BRIDGE=$CHAT_BRIDGE"

  CREDENTIALS_FILE="$SERVICE_HOME/.wp-opencode-credentials"
  write_file "$CREDENTIALS_FILE" "$CREDENTIALS_CONTENT"
  run_cmd chmod 600 "$CREDENTIALS_FILE"
  log "Credentials saved to $CREDENTIALS_FILE"
fi

echo "=============================================="
echo "Next steps"
echo "=============================================="
echo ""
if [ "$LOCAL_MODE" = true ]; then
  # Local mode next steps
  if [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ] && [ "$PLATFORM" = "mac" ]; then
    if [ -n "$KIMAKI_BOT_TOKEN" ]; then
      echo "  Kimaki (launchd service):"
      echo "    Start:  launchctl kickstart gui/$(id -u)/com.extrachill.kimaki"
      echo "    Stop:   launchctl kill SIGTERM gui/$(id -u)/com.extrachill.kimaki"
    else
      echo "  Kimaki setup:"
      echo "    1. Run onboarding:  cd $SITE_PATH && kimaki"
      echo "    2. Enable service:  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.extrachill.kimaki.plist"
    fi
    echo "    Logs:   tail -f $KIMAKI_DATA_DIR/kimaki.log"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "telegram" ] && [ "$PLATFORM" = "mac" ]; then
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
      echo "  Telegram (launchd services):"
      echo "    Start:  launchctl kickstart gui/$(id -u)/com.extrachill.opencode-serve"
      echo "            launchctl kickstart gui/$(id -u)/com.extrachill.opencode-telegram"
      echo "    Stop:   launchctl kill SIGTERM gui/$(id -u)/com.extrachill.opencode-serve"
      echo "            launchctl kill SIGTERM gui/$(id -u)/com.extrachill.opencode-telegram"
    else
      echo "  Telegram setup:"
      echo "    1. Add tokens to $SERVICE_HOME/.config/opencode-telegram-bot/.env"
      echo "    2. Enable services:"
      echo "       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.extrachill.opencode-serve.plist"
      echo "       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.extrachill.opencode-telegram.plist"
    fi
    echo "    Logs:   tail -f $SERVICE_HOME/.config/opencode-telegram-bot/opencode-serve.log"
    echo "            tail -f $SERVICE_HOME/.config/opencode-telegram-bot/opencode-telegram.log"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
    echo "  Start your agent:"
    echo "    cd $SITE_PATH && kimaki"
    echo ""
  elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "telegram" ]; then
    echo "  Start your agent:"
    echo "    cd $SITE_PATH && opencode serve &"
    echo "    opencode-telegram start"
    echo ""
  else
    echo "  Start your agent:"
    echo "    cd $SITE_PATH && opencode"
    echo ""
  fi
  if [ "$INSTALL_DATA_MACHINE" = true ]; then
    echo "  Configure Data Machine:"
    echo "    - Set AI provider API keys in WP Admin → Data Machine → Settings"
    echo "    - Or via WP-CLI: $WP_CMD datamachine settings --path=$SITE_PATH"
    echo ""
  fi
elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
  if [ -n "$KIMAKI_BOT_TOKEN" ]; then
    echo "  Bot token configured via KIMAKI_BOT_TOKEN."
    echo "  Start the agent:  systemctl start kimaki"
  else
    echo "  1. Set up Discord bot token:"
    echo "     Option A: Run kimaki interactively first (sets up database)"
    if [ "$RUN_AS_ROOT" = false ]; then
      echo "       su - $SERVICE_USER -c 'cd $SITE_PATH && kimaki'"
    else
      echo "       cd $SITE_PATH && kimaki"
    fi
    echo "     Option B: Set KIMAKI_BOT_TOKEN in the systemd service"
    echo "       systemctl edit kimaki"
    echo "       [Service]"
    echo "       Environment=KIMAKI_BOT_TOKEN=your-token-here"
    echo ""
    echo "  2. Start the agent:  systemctl start kimaki"
  fi
elif [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "telegram" ]; then
  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
    echo "  Telegram credentials configured. Start the agent:"
    echo "    systemctl start opencode-serve"
    echo "    systemctl start opencode-telegram"
  else
    echo "  1. Get your Telegram credentials:"
    echo "     - Bot token: message @BotFather → /newbot"
    echo "     - Your user ID: message @userinfobot"
    echo ""
    echo "  2. Add credentials to the bot config:"
    echo "     Edit $SERVICE_HOME/.config/opencode-telegram-bot/.env"
    echo "     Set TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USER_ID"
    echo ""
    echo "  3. Start the agent:"
    echo "     systemctl start opencode-serve"
    echo "     systemctl start opencode-telegram"
  fi
else
  echo "  No chat bridge installed. Run OpenCode manually:"
  echo "    cd $SITE_PATH && opencode"
fi
echo ""
if [ "$LOCAL_MODE" = false ] && [ "$INSTALL_DATA_MACHINE" = true ]; then
  echo "  Configure Data Machine:"
  echo "    - Set AI provider API keys in WP Admin → Data Machine → Settings"
  echo "    - Or via WP-CLI: $WP_CMD datamachine settings --allow-root"
  echo ""
fi
echo "  Your agent will read BOOTSTRAP.md on first run."
echo ""
