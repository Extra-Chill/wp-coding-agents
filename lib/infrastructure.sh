#!/bin/bash
# Infrastructure: system deps, nginx, SSL, service users

install_system_deps() {
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
    log "Skipping system dependencies (--skip-deps or --local)"
  fi
}

create_service_user() {
  if [ "$LOCAL_MODE" = false ] && [ "$RUN_AS_ROOT" = false ]; then
    if ! id -u "$SERVICE_USER" &>/dev/null || [ "$DRY_RUN" = true ]; then
      log "Phase 3.9: Creating service user '$SERVICE_USER'..."
      run_cmd useradd -m -s /bin/bash -G www-data "$SERVICE_USER"
    fi
  fi
}

setup_nginx() {
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
}

setup_ssl() {
  if [ "$SKIP_SSL" = true ]; then
    log "Skipping SSL (--skip-ssl)"
    return
  fi

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
}

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
  run_cmd chmod 640 "$config"
}

setup_service_permissions() {
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

    run_cmd chmod -R g+w "$SITE_PATH"
    run_cmd chown -R www-data:www-data "$SITE_PATH"
    harden_wp_config_permissions "$SITE_PATH"

    run_cmd mkdir -p "$KIMAKI_DATA_DIR"
    run_cmd chown -R "$SERVICE_USER:$SERVICE_USER" "$KIMAKI_DATA_DIR"
  else
    log "Phase 6: Running as root (--root)"
    run_cmd mkdir -p "$KIMAKI_DATA_DIR"
  fi
}
