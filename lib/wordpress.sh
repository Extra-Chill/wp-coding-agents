#!/bin/bash
# WordPress operations: WP-CLI helpers, install, database, multisite

# Run a WP-CLI command with the correct flags for the current platform.
wp_cmd() {
  wp_cli_transport_ensure
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    local user_args=()
    [ -z "${WORDPRESS_USER:-}" ] || user_args=("--user=$WORDPRESS_USER")
    run_cmd "${WP_CLI_TRANSPORT[@]}" "${user_args[@]}" "--path=$WORDPRESS_PATH" "$@"
    return
  fi
  run_cmd "${WP_CLI_TRANSPORT[@]}" "$@" $WP_ROOT_FLAG --path="$SITE_PATH"
}

# Compose registered files as the actual owner of SITE_PATH. Data Machine
# atomically replaces files in that directory, and its euid detection controls
# whether generated WP-CLI guidance includes --allow-root.
wp_run_as_site_owner() {
  local owner current_user service_home status
  if [ "${LOCAL_MODE:-false}" = true ]; then
    wp_cli "$@" $WP_ROOT_FLAG
    return $?
  fi

  owner="$(file_owner "$SITE_PATH" 2>/dev/null)" || {
    printf '%s\n' "AGENTS.md compose failed [site_owner_unavailable]: cannot determine SITE_PATH owner; check that SITE_PATH exists and is accessible." >&2
    return 1
  }
  if [ -n "${WP_CODING_AGENTS_COMPOSE_USER:-}" ] && [ "$WP_CODING_AGENTS_COMPOSE_USER" != "$owner" ]; then
    printf 'AGENTS.md compose failed [compose_identity_mismatch]: configured compose identity does not match SITE_PATH owner %s; align WP_CODING_AGENTS_COMPOSE_USER or directory ownership.\n' "$owner" >&2
    return 1
  fi

  if [ "$owner" = root ] && [ -n "${SERVICE_USER:-}" ] && [ "$SERVICE_USER" != root ]; then
    printf '%s\n' 'AGENTS.md compose failed [root_owned_site_for_nonroot_service]: a non-root managed service cannot receive correct non-root guidance from a root-owned SITE_PATH. Assign SITE_PATH to the service/site owner, then re-run upgrade.' >&2
    return 1
  fi

  current_user="$(id -un)"
  if [ "$current_user" = "$owner" ]; then
    wp_cli "$@" $WP_ROOT_FLAG
    return $?
  fi

  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n -H -u "$owner" test -w "$SITE_PATH" >/dev/null 2>&1; then
    printf 'AGENTS.md compose failed [cannot_switch_to_site_owner]: SITE_PATH owner %s is not writable through non-interactive sudo; run upgrade as root or repair ownership/permissions. AGENTS.md was not composed.\n' "$owner" >&2
    return 1
  fi

  # sudo -H selects the target account's HOME; preserve the managed service's
  # configured HOME when the site owner is that service identity.
  service_home=""
  [ "$owner" != "${SERVICE_USER:-}" ] || service_home="${SERVICE_HOME:-}"
  wp_cli_transport_ensure
  if [ -n "$service_home" ]; then
    sudo -n -H -u "$owner" env HOME="$service_home" PATH="$PATH" "${WP_CLI_TRANSPORT[@]}" "$@" >/dev/null 2>&1
  else
    sudo -n -H -u "$owner" env PATH="$PATH" "${WP_CLI_TRANSPORT[@]}" "$@" >/dev/null 2>&1
  fi
  status=$?
  if [ "$status" -ne 0 ]; then
    printf 'AGENTS.md compose failed [compose_command_failed]: WP-CLI composition as SITE_PATH owner %s returned status %s; inspect WordPress/Data Machine health and retry. CLI output was suppressed.\n' "$owner" "$status" >&2
  fi
  return "$status"
}

# Activate a plugin, handling multisite --url= branching.
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
install_plugin() {
  local slug="$1"
  local repo_url="$2"
  local plugin_dir="$SITE_PATH/wp-content/plugins/$slug"

  if [ ! -d "$plugin_dir" ] || [ "$DRY_RUN" = true ]; then
    git_clone_with_retry "$repo_url" "$plugin_dir" || \
      warn "Clone failed for $slug — install will continue without it"
  elif [ -d "$plugin_dir/.git" ]; then
    log "Plugin $slug already exists — pulling latest..."
    run_cmd git -C "$plugin_dir" pull --ff-only 2>/dev/null || \
      warn "Could not pull latest $slug — check for local changes"
  fi

  install_plugin_dependencies "$slug" "$plugin_dir" false

  activate_plugin "$slug"
  fix_ownership "$plugin_dir"
}

# Install/build plugin dependencies. Set force=true after a code update so lockfile
# or asset changes are applied even when vendor/node_modules already exist.
install_plugin_dependencies() {
  local slug="$1"
  local plugin_dir="$2"
  local force="${3:-false}"

  if [ -f "$plugin_dir/composer.json" ] && { [ "$force" = true ] || [ ! -d "$plugin_dir/vendor" ] || [ "$DRY_RUN" = true ]; }; then
    run_cmd env COMPOSER_ALLOW_SUPERUSER=1 composer install \
      --no-dev --no-interaction --working-dir="$plugin_dir" || \
      warn "Composer failed, some $slug features may not work"
  fi
  if [ -f "$plugin_dir/package.json" ] && { [ "$force" = true ] || [ ! -d "$plugin_dir/node_modules" ] || [ "$DRY_RUN" = true ]; }; then
    log "Building $slug JS assets..."
    run_cmd npm install --prefix "$plugin_dir" || \
      warn "npm install failed for $slug"

    # Some plugins' `npm run build` is a wp-env/Docker wrapper around steps
    # we already ran natively (e.g. mcp-adapter's build is just `composer
    # install` inside wp-env). Studio installs don't have Docker, so wp-env
    # fails loudly on the canonical setup path. Skip the build in that
    # case — the host-side composer install above already produced the
    # runtime artifacts.
    local build_script
    build_script=$(jq -r '.scripts.build // ""' "$plugin_dir/package.json" 2>/dev/null)
    if echo "$build_script" | grep -q "wp-env" && ! docker info &>/dev/null; then
      log "Skipping $slug build — script requires wp-env (Docker daemon not reachable)."
    else
      run_cmd npm run build --prefix "$plugin_dir" || \
        warn "npm build failed for $slug — admin pages may not work"
    fi
  fi
}

# Update a git-installed plugin to its latest version tag.
update_plugin_to_latest_tag() {
  local slug="$1"
  local repo_url="$2"
  local plugin_dir="$SITE_PATH/wp-content/plugins/$slug"

  if [ ! -d "$plugin_dir" ]; then
    log "Plugin $slug missing — installing before tag checkout..."
    install_plugin "$slug" "$repo_url"
    [ ! -d "$plugin_dir" ] || PLUGIN_UPDATE_MUTATED=true
  fi

  if [ ! -d "$plugin_dir/.git" ]; then
    warn "Plugin $slug is not a git checkout — skipping tagged release update"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} git -C $plugin_dir fetch --tags --force origin"
    echo -e "${BLUE}[dry-run]${NC} git -C $plugin_dir checkout --detach <latest-tag>"
    echo -e "${BLUE}[dry-run]${NC} Would rebuild dependencies for $slug if composer.json/package.json exist"
    return 0
  fi

  local phase_status
  if plugin_update_run_phase "$slug" working-tree-inspection git -C "$plugin_dir" status --porcelain; then
    :
  else
    phase_status=$?
    warn "Could not inspect the $slug working tree"
    return "$phase_status"
  fi
  if [ -n "$PLUGIN_PHASE_OUTPUT" ]; then
    warn "Plugin $slug has local changes — skipping tagged release update"
    return 0
  fi

  if plugin_update_run_phase "$slug" tag-fetch git -C "$plugin_dir" fetch --tags --force origin; then
    :
  else
    phase_status=$?
    warn "Could not fetch tags for $slug"
    return "$phase_status"
  fi

  local latest_tag
  if plugin_update_run_phase "$slug" tag-discovery git -C "$plugin_dir" tag --sort=-v:refname; then
    :
  else
    phase_status=$?
    warn "Could not inspect tags for $slug"
    return "$phase_status"
  fi
  latest_tag=$(printf '%s\n' "$PLUGIN_PHASE_OUTPUT" | grep -E '^v?[0-9]' | head -n 1)
  if [ -z "$latest_tag" ]; then
    warn "No version tags found for $slug — skipping"
    return 1
  fi

  local current_ref
  if plugin_update_run_phase "$slug" current-release bash -c \
      'git -C "$1" describe --tags --exact-match 2>/dev/null || git -C "$1" rev-parse --short HEAD' _ "$plugin_dir"; then
    current_ref="$PLUGIN_PHASE_OUTPUT"
  else
    phase_status=$?
    warn "Could not identify the installed release for $slug"
    return "$phase_status"
  fi

  if [ "$current_ref" = "$latest_tag" ]; then
    log "Plugin $slug already at latest tag ($latest_tag)"
  else
    log "Updating plugin $slug: $current_ref → $latest_tag"
    if plugin_update_run_phase "$slug" release-checkout git -C "$plugin_dir" checkout --detach "$latest_tag"; then
      :
    else
      phase_status=$?
      warn "Could not checkout $latest_tag for $slug"
      return "$phase_status"
    fi
    UPDATED_ITEMS+=("$slug $latest_tag")
    PLUGIN_UPDATE_MUTATED=true
  fi

  install_plugin_dependencies_bounded "$slug" "$plugin_dir" || return $?
  plugin_update_run_phase "$slug" ownership-normalization fix_ownership "$plugin_dir" || return $?
}

install_plugin_dependencies_bounded() {
  local slug="$1" plugin_dir="$2"
  if [ -f "$plugin_dir/composer.json" ]; then
    plugin_update_run_phase "$slug" composer-install env COMPOSER_ALLOW_SUPERUSER=1 composer install \
      --no-dev --no-interaction --working-dir="$plugin_dir" || return $?
  fi
  if [ -f "$plugin_dir/package.json" ]; then
    log "Building $slug JS assets..."
    plugin_update_run_phase "$slug" npm-install npm install --prefix "$plugin_dir" || return $?
    plugin_update_run_phase "$slug" build-script-inspection jq -r '.scripts.build // ""' "$plugin_dir/package.json" || return $?
    local build_script="$PLUGIN_PHASE_OUTPUT"
    if printf '%s' "$build_script" | grep -q "wp-env"; then
      if ! command -v docker >/dev/null 2>&1; then
        log "Skipping $slug build — script requires wp-env (Docker is not installed)."
      elif plugin_update_run_phase "$slug" docker-readiness docker info; then
        plugin_update_run_phase "$slug" npm-build npm run build --prefix "$plugin_dir" || return $?
      else
        log "Skipping $slug build — script requires wp-env (Docker daemon not reachable within the plugin phase deadline)."
      fi
    else
      plugin_update_run_phase "$slug" npm-build npm run build --prefix "$plugin_dir" || return $?
    fi
  fi
}

# Normalize web-tree ownership or group permissions (no-op in local mode).
fix_ownership() {
  if [ "$LOCAL_MODE" = false ]; then
    if [ "$(id -u)" -eq 0 ]; then
      run_cmd chown -R www-data:www-data "$1"
    elif [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} normalize group-writable permissions for $1"
    else
      service_dir_normalize_perms "$1"
    fi
  fi
}

install_extra_plugins() {
  if [ -z "${EXTRA_PLUGINS:-}" ]; then
    return
  fi

  log "Installing extra plugins..."
  for entry in $EXTRA_PLUGINS; do
    slug="${entry%%:*}"
    url="${entry#*:}"
    if [ -z "$slug" ] || [ -z "$url" ]; then
      warn "Skipping malformed EXTRA_PLUGINS entry: $entry"
      continue
    fi
    install_plugin "$slug" "$url"
  done
}

setup_database() {
  if [ "$MODE" = "fresh" ]; then
    log "Phase 2: Configuring database..."
    run_cmd mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    run_cmd mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    run_cmd mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    run_cmd mysql -e "FLUSH PRIVILEGES;"
  else
    log "Phase 2: Using existing database"
  fi
}

install_wordpress() {
  if [ "$MODE" = "fresh" ]; then
    log "Phase 3: Installing WordPress..."
    run_cmd mkdir -p "$SITE_PATH"
    if [ "$DRY_RUN" = false ]; then
      cd "$SITE_PATH"
    fi

    if [ ! -f wp-config.php ] || [ "$DRY_RUN" = true ]; then
      wp_cli_transport_ensure
      run_cmd "${WP_CLI_TRANSPORT[@]}" core download --allow-root
      run_cmd "${WP_CLI_TRANSPORT[@]}" config create --allow-root \
        --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost="localhost"
      run_cmd "${WP_CLI_TRANSPORT[@]}" core install --allow-root \
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
}

setup_multisite() {
  if [ "$MULTISITE" = true ] && [ "$MODE" = "fresh" ]; then
    log "Phase 3.5: Converting to WordPress Multisite ($MULTISITE_TYPE)..."

    if [ "$MULTISITE_TYPE" = "subdomain" ]; then
      wp_cli_transport_ensure
      run_cmd "${WP_CLI_TRANSPORT[@]}" core multisite-convert --subdomains --allow-root --path="$SITE_PATH"
    else
      wp_cli_transport_ensure
      run_cmd "${WP_CLI_TRANSPORT[@]}" core multisite-convert --allow-root --path="$SITE_PATH"
    fi

    log "Multisite conversion complete"
  elif [ "$MULTISITE" = true ] && [ "$MODE" = "existing" ]; then
    log "Phase 3.5: Existing multisite detected — skipping conversion"
  fi
}

# Moved here from lib/infrastructure.sh, which setup.sh sources and upgrade.sh
# does not. The service-identity migration called this behind a
# `declare -F` guard, so on an upgrade the function did not exist, the guard
# silently skipped it, and wp-config.php was left group-writable by the blanket
# `chmod -R g+w` that runs just before. A guard around a function you REQUIRE
# converts a missing dependency into silent breakage; the call site is now
# unconditional and this lives where every caller already sources it.
# Restrict the credentials file after the site-wide grant (issue #302).
#
# The recursive `chmod -R g+w` above exists so the service user — a member of
# www-data — can edit themes and plugins. Applied to the whole site path it
# also sweeps in wp-config.php, which holds the database credentials, salts,
# and auth keys. That leaves the file world-readable (any local account can
# read the credentials) and agent-writable (the coding agent can rewrite the
# site's database connection), neither of which the agent needs.
#
# 0640 owned by www-data keeps PHP-FPM and nginx working — both run as
# www-data on a standard provision — while removing world read and group
# write. Applied unconditionally so re-running provisioning corrects a mode
# an earlier install left loosened, rather than only fixing fresh sites.
harden_wp_config_permissions() {
  local site_path="$1"
  local config="$site_path/wp-config.php"

  if [ "$DRY_RUN" != true ] && [ ! -f "$config" ]; then
    return 0
  fi

  run_cmd chown www-data:www-data "$config"
  local mode=640
  if printf '%s\n' "${OWNED_WRITABLE:-}" | tr ' ' '\n' | grep -qx 'wp-config.php'; then
    mode=660
  fi
  run_cmd chmod "$mode" "$config"
}
