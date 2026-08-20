#!/bin/bash
# Environment detection: OS, PHP, Studio, multisite, variable resolution

detect_php_version() {
  if command -v php &> /dev/null; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    log "Detected existing PHP version: $PHP_VERSION"
    return
  fi

  if [ "${SKIP_DEPS:-false}" = true ]; then
    PHP_VERSION=""
    warn "PHP is unavailable and dependency installation is disabled"
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

detect_root_requirement() {
  if [ "${DRY_RUN:-false}" = true ] || [ "${LOCAL_MODE:-false}" = true ]; then
    return 0
  fi

  if [ "${REQUIRE_ROOT_DURING_DETECT:-true}" != true ]; then
    return 0
  fi

  if [ "$EUID" -ne 0 ]; then
    error "Please run as root (sudo ./setup.sh). Use --local for local installs."
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

  # Check root when the caller requires root during detection. setup.sh uses
  # the default. upgrade.sh defers this until after it can adopt the installed
  # service identity from existing systemd units.
  detect_root_requirement

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
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    # SITE_PATH remains the legacy runtime destination for modules that have not
    # needed a distinct root. It never denotes the remote WordPress filesystem.
    SITE_PATH="$RUNTIME_PROJECT_ROOT"
    SITE_DOMAIN="${SITE_DOMAIN:-$(basename "$WORDPRESS_PATH")}"
    log "External WordPress at: $WORDPRESS_PATH (runtime: $RUNTIME_PROJECT_ROOT)"
  elif [ "$MODE" = "existing" ]; then
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

    local detected_site_domain=""
    if [ "$DRY_RUN" = true ]; then
      detected_site_domain="${SITE_DOMAIN:-}"
    elif [ "$IS_STUDIO" = true ]; then
      detected_site_domain=$(studio wp option get siteurl --path="$SITE_PATH" 2>/dev/null | sed -E 's|^https?://||' || true)
    else
      detected_site_domain=$(cd "$SITE_PATH" && $WP_CMD option get siteurl $WP_ROOT_FLAG 2>/dev/null | sed -E 's|^https?://||' || true)
    fi
    SITE_DOMAIN="${SITE_DOMAIN:-${detected_site_domain:-$(basename "$SITE_PATH")}}"
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

  detect_service_identity
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ] && [ "${KIMAKI_DATA_DIR_EXPLICIT:-false}" != true ]; then
    KIMAKI_DATA_DIR="$RUNTIME_PROJECT_ROOT/.kimaki"
  fi
}

# Derive SERVICE_USER / SERVICE_HOME / KIMAKI_DATA_DIR / DM_WORKSPACE_DIR from
# LOCAL_MODE and RUN_AS_ROOT.
#
# Split out of detect_environment so it can be re-derived. setup.sh resolves the
# source mode AFTER detection — the mode is read from the site, which detection
# is what finds — and the owned mode defaults to a non-root service user (#327).
# Without a way to recompute, that default could only flip RUN_AS_ROOT and would
# leave SERVICE_USER, the service home, and the data dir all still pointing at
# root: exactly the half-applied identity that #204 and #93 are both about.
#
# Idempotent. KIMAKI_DATA_DIR is recomputed unless the operator set it
# explicitly (env var or --kimaki-data-dir), so a second call cannot pin the
# data dir to the home of the identity that was current on the first call.
detect_service_identity() {
  if [ "$LOCAL_MODE" = true ]; then
    SERVICE_USER="$(whoami)"
    SERVICE_HOME="$HOME"
    _detect_default_kimaki_data_dir "$HOME/.kimaki"
    DM_WORKSPACE_DIR="${DATAMACHINE_WORKSPACE_PATH:-$HOME/.datamachine/workspace}"
  elif [ "$RUN_AS_ROOT" = true ]; then
    SERVICE_USER="root"
    SERVICE_HOME="/root"
    _detect_default_kimaki_data_dir "/root/.kimaki"
    DM_WORKSPACE_DIR="${DATAMACHINE_WORKSPACE_PATH:-/var/lib/datamachine/workspace}"
  else
    SERVICE_USER="opencode"
    SERVICE_HOME="/home/opencode"
    _detect_default_kimaki_data_dir "/home/opencode/.kimaki"
    DM_WORKSPACE_DIR="${DATAMACHINE_WORKSPACE_PATH:-/var/lib/datamachine/workspace}"
  fi
}

_detect_default_kimaki_data_dir() {
  # An operator-set data dir is never relocated.
  if [ "${KIMAKI_DATA_DIR_EXPLICIT:-}" = true ]; then
    return 0
  fi

  # This used to be `KIMAKI_DATA_DIR="${KIMAKI_DATA_DIR:-<default>}"`, which
  # cannot be re-derived: the second call sees the value the first one wrote and
  # keeps the old identity's home. The EXPLICIT flag replaces it, and both real
  # entry points set that flag (initialize_kimaki_overrides) before detecting.
  # When the flag machinery has not run at all, fall back to the historical
  # behaviour rather than silently relocating a caller that only exported the
  # variable.
  if [ -z "${KIMAKI_DATA_DIR_EXPLICIT+x}" ] && [ -n "${KIMAKI_DATA_DIR:-}" ]; then
    return 0
  fi

  KIMAKI_DATA_DIR="$1"
}

# Owned mode defaults to a non-root service user (#327).
#
# The edit denies are a guardrail, not containment: `permission.edit` gates the
# runtime's edit tool only, `bash` is a separate key that is unset (and so
# allowed), and a root service reaches every denied path through `bash -c`,
# `wp eval`, or a PHP one-liner. The service user is the lever that actually
# holds, because the kernel enforces it rather than a config file.
#
# Scoped to owned mode deliberately. That is the shape aimed at owners who
# cannot evaluate the risk — a site whose operator never opens a terminal should
# not carry an agent with an unrestricted root shell. A workspace install
# belongs to a developer who chose it, so its default is left alone and the
# migration (upgrade.sh --migrate-non-root) is offered instead.
#
# A DEFAULT only: --root and --non-root both set SERVICE_USER_FORCED, which
# means the operator already decided and is not second-guessed. Applies to fresh
# installs; an existing install is never flipped implicitly (#204), because that
# would strand the agent's state in the old home.
#
# Lives here rather than inline in setup.sh because setup.sh resolves the source
# mode AFTER detection — the mode is read from the site, which detection is what
# finds — so this has to re-derive the identity, and a re-derivation is worth
# testing directly.
detect_apply_source_mode_identity_default() {
  [ "${SOURCE_MODE:-}" = "owned" ] || return 0
  [ "${SERVICE_USER_FORCED:-false}" = false ] || return 0
  [ "${LOCAL_MODE:-false}" = false ] || return 0
  [ "${RUN_AS_ROOT:-true}" = true ] || return 0

  RUN_AS_ROOT=false
  detect_service_identity
  log "Owned mode: defaulting to non-root service user '$SERVICE_USER' (pass --root to override)"
}
