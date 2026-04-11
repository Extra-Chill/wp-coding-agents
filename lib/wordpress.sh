#!/bin/bash
# WordPress operations: WP-CLI helpers, install, database, multisite

# Run a WP-CLI command with the correct flags for the current platform.
wp_cmd() {
  if [ "$IS_STUDIO" = true ]; then
    # shellcheck disable=SC2086
    run_cmd studio wp "$@"
  else
    # shellcheck disable=SC2086
    run_cmd $WP_CMD "$@" $WP_ROOT_FLAG --path="$SITE_PATH"
  fi
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
    # Prefer gh CLI for GitHub repos (avoids proxy/auth issues).
    local gh_nwo
    gh_nwo=$(echo "$repo_url" | sed -n 's|^https://github\.com/\([^/]*/[^/]*\)\(\.git\)\{0,1\}$|\1|p')
    if [ -n "$gh_nwo" ] && command -v gh &>/dev/null; then
      run_cmd gh repo clone "$gh_nwo" "$plugin_dir"
    else
      run_cmd git clone "$repo_url" "$plugin_dir"
    fi
  fi

  # Install dependencies even if plugin was pre-cloned.
  if [ -f "$plugin_dir/composer.json" ] && { [ ! -d "$plugin_dir/vendor" ] || [ "$DRY_RUN" = true ]; }; then
    run_cmd env COMPOSER_ALLOW_SUPERUSER=1 composer install \
      --no-dev --no-interaction --working-dir="$plugin_dir" || \
      warn "Composer failed, some $slug features may not work"
  fi
  if [ -f "$plugin_dir/package.json" ] && { [ ! -d "$plugin_dir/node_modules" ] || [ "$DRY_RUN" = true ]; }; then
    log "Building $slug JS assets..."
    run_cmd npm install --prefix "$plugin_dir" || \
      warn "npm install failed for $slug"
    run_cmd npm run build --prefix "$plugin_dir" || \
      warn "npm build failed for $slug — admin pages may not work"
  fi

  activate_plugin "$slug"
  fix_ownership "$plugin_dir"
}

# Set file ownership to www-data (no-op in local mode).
fix_ownership() {
  if [ "$LOCAL_MODE" = false ]; then
    run_cmd chown -R www-data:www-data "$1"
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
}

setup_multisite() {
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
}
