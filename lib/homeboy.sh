#!/bin/bash
# Homeboy project registration plus optional WordPress extension readiness.

HOMEBOY_EXTENSIONS_SOURCE_DEFAULT="https://github.com/Extra-Chill/homeboy-extensions.git"
HOMEBOY_WORDPRESS_READY=false

homeboy_slugify() {
  printf '%s' "$1" | sed 's|https\?://||; s|/.*$||; s|\..*$||' | \
    tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

homeboy_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

homeboy_project_json() {
  local domain base_path server_id
  domain="$(homeboy_json_escape "$1")"
  base_path="$(homeboy_json_escape "$2")"
  server_id="$(homeboy_json_escape "${3:-}")"

  printf '{"domain":"%s","base_path":"%s"' "$domain" "$base_path"
  if [ -n "$server_id" ]; then
    printf ',"server_id":"%s"' "$server_id"
  fi
  printf '}'
}

homeboy_server_json() {
  local user port
  user="$(homeboy_json_escape "$1")"
  port="$2"
  printf '{"host":"localhost","user":"%s","port":%s}' "$user" "$port"
}

homeboy_project_id() {
  if [ -n "${HOMEBOY_PROJECT_ID:-}" ]; then
    printf '%s' "$HOMEBOY_PROJECT_ID"
  elif [ -n "${AGENT_SLUG:-}" ]; then
    printf '%s' "$AGENT_SLUG"
  else
    homeboy_slugify "${SITE_DOMAIN:-$SITE_PATH}"
  fi
}

homeboy_server_id() {
  if [ "$LOCAL_MODE" = true ]; then
    printf 'local'
    return 0
  fi

  if [ -n "${HOMEBOY_SERVER_ID:-}" ]; then
    printf '%s' "$HOMEBOY_SERVER_ID"
    return 0
  fi

  if [ "$DRY_RUN" = false ] && homeboy server show "$SITE_DOMAIN" >/dev/null 2>&1; then
    printf '%s' "$SITE_DOMAIN"
  fi

  return 0
}

ensure_homeboy_local_server() {
  if [ "$LOCAL_MODE" != true ]; then
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy server set local --json '{\"host\":\"localhost\",\"user\":\"$(whoami)\",\"port\":22}'"
    return 0
  fi

  if homeboy server show local >/dev/null 2>&1; then
    homeboy server set local --json "$(homeboy_server_json "$(whoami)" 22)" >/dev/null
  else
    homeboy server create local --host localhost --user "$(whoami)" --port 22 >/dev/null
  fi
}

homeboy_wordpress_extension_ready() {
  command -v homeboy >/dev/null 2>&1 || return 1

  local list_json
  list_json=$(homeboy extension list 2>/dev/null) || return 1

  printf '%s' "$list_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
extensions = data.get("data", {}).get("extensions", [])
for extension in extensions:
    if extension.get("id") == "wordpress":
        if extension.get("ready") is True and extension.get("compatible") is not False:
            sys.exit(0)
        sys.exit(1)
sys.exit(1)
' >/dev/null 2>&1
}

homeboy_wordpress_extension_linked() {
  command -v homeboy >/dev/null 2>&1 || return 1

  local show_json
  show_json=$(homeboy extension show wordpress 2>/dev/null) || return 1

  printf '%s' "$show_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("data", {}).get("extension", {}).get("linked") is True else 1)
' >/dev/null 2>&1
}

homeboy_required() {
  [ "${HOMEBOY_MODE:-auto}" = "enabled" ] || [ "${WITH_HOMEBOY:-false}" = true ]
}

homeboy_handle_failure() {
  local message="$1"
  if homeboy_required; then
    error "$message"
  fi
  warn "$message"
  return 0
}

setup_homeboy_project() {
  if [ "${HOMEBOY_MODE:-auto}" = "disabled" ]; then
    log "Skipping Homeboy project setup (--no-homeboy)"
    return 0
  fi

  if ! command -v homeboy >/dev/null 2>&1; then
    if homeboy_required; then
      error "Homeboy project setup requested, but the 'homeboy' command was not found"
    fi
    log "Skipping Homeboy project setup (homeboy not installed)"
    return 0
  fi

  local project_id server_id spec
  project_id="$(homeboy_project_id)"
  HOMEBOY_PROJECT_ID="$project_id"
  server_id="$(homeboy_server_id)"
  HOMEBOY_SERVER_ID_RESOLVED="$server_id"
  spec="$(homeboy_project_json "$SITE_DOMAIN" "$SITE_PATH" "$server_id")"

  log "Phase 4.6: Creating/updating Homeboy project '$project_id' for WordPress site"
  log "Homeboy project target: domain=$SITE_DOMAIN path=$SITE_PATH${server_id:+ server=$server_id}"

  ensure_homeboy_local_server

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy project set $project_id --json '$spec' || homeboy project create $project_id $SITE_DOMAIN --base-path '$SITE_PATH'${server_id:+ --server-id $server_id}"
    return 0
  fi

  if homeboy project show "$project_id" >/dev/null 2>&1; then
    homeboy project set "$project_id" --json "$spec" >/dev/null
    log "Updated Homeboy project '$project_id'"
  else
    if [ -n "$server_id" ]; then
      homeboy project create "$project_id" "$SITE_DOMAIN" --base-path "$SITE_PATH" --server-id "$server_id" >/dev/null
    else
      homeboy project create "$project_id" "$SITE_DOMAIN" --base-path "$SITE_PATH" >/dev/null
    fi
    log "Created Homeboy project '$project_id'"
  fi
}

configure_homeboy_wordpress_extension() {
  HOMEBOY_WORDPRESS_READY=false

  if [ "${HOMEBOY_MODE:-auto}" = "disabled" ]; then
    sync_homeboy_availability
    recompose_agents_md_for_homeboy
    return 0
  fi

  if ! command -v homeboy >/dev/null 2>&1; then
    homeboy_handle_failure "Homeboy is not callable from this setup/runtime PATH; skipping Homeboy WordPress extension setup."
    sync_homeboy_availability
    recompose_agents_md_for_homeboy
    return 0
  fi

  log "Detected Homeboy: $(command -v homeboy)"

  if ! homeboy_required; then
    if homeboy_wordpress_extension_ready; then
      HOMEBOY_WORDPRESS_READY=true
      log "Homeboy WordPress extension is installed and ready."
    else
      warn "Homeboy is callable, but the WordPress extension is not ready. Run setup with --with-homeboy to install and verify it."
    fi
    sync_homeboy_availability
    recompose_agents_md_for_homeboy
    return 0
  fi

  local source="${HOMEBOY_EXTENSIONS_SOURCE:-$HOMEBOY_EXTENSIONS_SOURCE_DEFAULT}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy extension install $source --id wordpress"
    echo -e "${BLUE}[dry-run]${NC} homeboy extension update wordpress  # if already installed and not linked"
    echo -e "${BLUE}[dry-run]${NC} homeboy extension setup wordpress"
    echo -e "${BLUE}[dry-run]${NC} homeboy extension list"
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update datamachine_code_homeboy_available 1"
    print_homeboy_verification_commands
    return 0
  fi

  if homeboy extension show wordpress >/dev/null 2>&1; then
    if homeboy_wordpress_extension_linked; then
      log "Homeboy WordPress extension is linked locally — skipping git update."
    else
      log "Updating Homeboy WordPress extension..."
      homeboy extension update wordpress >/dev/null || homeboy_handle_failure "Homeboy WordPress extension update failed."
    fi
  else
    log "Installing Homeboy WordPress extension from $source..."
    homeboy extension install "$source" --id wordpress >/dev/null || homeboy_handle_failure "Homeboy WordPress extension install failed from $source."
  fi

  log "Running Homeboy WordPress extension setup..."
  homeboy extension setup wordpress >/dev/null || homeboy_handle_failure "Homeboy WordPress extension setup failed."

  if homeboy_wordpress_extension_ready; then
    HOMEBOY_WORDPRESS_READY=true
    log "Homeboy WordPress extension is ready."
  else
    homeboy_handle_failure "Homeboy WordPress extension did not pass readiness verification."
  fi

  sync_homeboy_availability
  recompose_agents_md_for_homeboy
  print_homeboy_verification_commands
}

recompose_agents_md_for_homeboy() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD datamachine memory compose AGENTS.md $WP_ROOT_FLAG"
    return 0
  fi

  if [ ! -f "$SITE_PATH/wp-config.php" ] && [ ! -f "$SITE_PATH/wp-load.php" ]; then
    return 0
  fi

  if (cd "$SITE_PATH" && $WP_CMD datamachine memory compose AGENTS.md $WP_ROOT_FLAG >/dev/null 2>&1); then
    log "AGENTS.md recomposed after Homeboy availability sync."
  else
    homeboy_handle_failure "Could not recompose AGENTS.md after Homeboy availability sync."
  fi
}

print_homeboy_verification_commands() {
  log "Homeboy verification commands:"
  echo "  homeboy extension list"
  echo "  homeboy extension show wordpress"
  echo "  homeboy project show <project-id>"
  echo "  homeboy project components list <project-id>"
}
