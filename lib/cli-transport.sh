#!/bin/bash
# lib/cli-transport.sh — wp-coding-agents-owned CLI dispatch transport writer.

cli_transport_mu_plugin_path() {
  if [ -z "${SITE_PATH:-}" ]; then
    return 1
  fi
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-cli-transport.php"
}

cli_transport_install() {
  local file template dir
  file="$(cli_transport_mu_plugin_path)" || {
    warn "  cli_transport_install: SITE_PATH not set — skipping"
    return 1
  }
  template="$SCRIPT_DIR/templates/wp-coding-agents-cli-transport.php"
  if [ ! -f "$template" ]; then
    warn "  cli_transport_install: missing template $template"
    return 1
  fi

  dir="${file%/*}"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mkdir -p $dir"
    echo -e "${BLUE}[dry-run]${NC} Would sync CLI transport mu-plugin to $file"
    return 0
  fi

  mkdir -p "$dir"
  if [ -f "$file" ] && cmp -s "$template" "$file"; then
    service_file_normalize_perms "$file"
    return 0
  fi

  cp "$template" "$file"
  service_file_normalize_perms "$file"
  log "  Synced CLI transport mu-plugin: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("CLI transport runtime")
  fi
}
