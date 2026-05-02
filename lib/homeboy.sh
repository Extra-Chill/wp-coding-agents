#!/bin/bash
# Homeboy project registration for the installed WordPress site.

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

setup_homeboy_project() {
  if [ "${HOMEBOY_MODE:-auto}" = "disabled" ]; then
    log "Skipping Homeboy project setup (--no-homeboy)"
    return 0
  fi

  if ! command -v homeboy >/dev/null 2>&1; then
    if [ "${HOMEBOY_MODE:-auto}" = "enabled" ]; then
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
