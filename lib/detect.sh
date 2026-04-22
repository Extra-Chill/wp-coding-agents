#!/bin/bash
# Environment detection: OS, PHP, Studio, multisite, variable resolution

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

detect_environment() {
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
  log "Runtime: $RUNTIME"
  log "Multisite: $MULTISITE ($MULTISITE_TYPE)"
  if [ "$DRY_RUN" = true ]; then
    log "Dry-run mode: commands will be printed, not executed"
  fi

  detect_php_version

  # Configuration
  if [ "$MODE" = "existing" ]; then
    if [ -z "$EXISTING_WP" ]; then
      error "EXISTING_WP must be set when using --existing mode or --wp-path"
    fi
    if [ "$DRY_RUN" = false ] && [ ! -f "$EXISTING_WP/wp-config.php" ] && [ ! -f "$EXISTING_WP/wp-load.php" ]; then
      error "No WordPress found at $EXISTING_WP (missing wp-config.php and wp-load.php)"
    fi
    SITE_PATH="$EXISTING_WP"
    # Normalize to absolute path
    if [ "$DRY_RUN" = false ]; then
      SITE_PATH=$(cd "$SITE_PATH" 2>/dev/null && pwd || echo "$SITE_PATH")
    fi

    # Detect WordPress Studio
    if command -v studio &> /dev/null && [ -f "$SITE_PATH/STUDIO.md" ]; then
      IS_STUDIO=true
      WP_CMD="studio wp"
      log "Detected WordPress Studio environment"
    fi

    if [ "$DRY_RUN" = true ]; then
      SITE_DOMAIN="${SITE_DOMAIN:-$(basename "$SITE_PATH")}"
    elif [ "$IS_STUDIO" = true ]; then
      SITE_DOMAIN=$(studio wp option get siteurl 2>/dev/null | sed 's|https\?://||' || basename "$SITE_PATH")
    else
      SITE_DOMAIN=$(cd "$SITE_PATH" && $WP_CMD option get siteurl $WP_ROOT_FLAG 2>/dev/null | sed 's|https\?://||' || basename "$SITE_PATH")
    fi
    log "Existing WordPress at: $SITE_PATH ($SITE_DOMAIN)"

    # Detect if existing WP is multisite
    if [ "$DRY_RUN" = false ]; then
      if [ "$IS_STUDIO" = true ]; then
        IS_EXISTING_MULTISITE=$(studio wp eval 'echo is_multisite() ? "yes" : "no";' 2>/dev/null || echo "no")
      else
        IS_EXISTING_MULTISITE=$(cd "$SITE_PATH" && $WP_CMD eval 'echo is_multisite() ? "yes" : "no";' $WP_ROOT_FLAG 2>/dev/null || echo "no")
      fi
      if [ "$IS_EXISTING_MULTISITE" = "yes" ]; then
        MULTISITE=true
        if [ "$IS_STUDIO" = true ]; then
          IS_SUBDOMAIN=$(studio wp eval 'echo is_subdomain_install() ? "yes" : "no";' 2>/dev/null || echo "no")
        else
          IS_SUBDOMAIN=$(cd "$SITE_PATH" && $WP_CMD eval 'echo is_subdomain_install() ? "yes" : "no";' $WP_ROOT_FLAG 2>/dev/null || echo "no")
        fi
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
}
