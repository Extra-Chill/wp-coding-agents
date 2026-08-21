#!/bin/bash
# Generated durable inbound event bridge installer.

inbound_event_bridge_mu_plugin_path() {
  [ -n "${SITE_PATH:-}" ] || return 1
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-inbound-events.php"
}

inbound_event_bridge_install() {
  local file template dir
  file="$(inbound_event_bridge_mu_plugin_path)" || { warn "  inbound_event_bridge_install: SITE_PATH not set — skipping"; return 1; }
  template="$SCRIPT_DIR/templates/wp-coding-agents-inbound-events.php"
  [ -f "$template" ] || { warn "  inbound_event_bridge_install: missing template $template"; return 1; }
  dir="${file%/*}"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would sync inbound event bridge mu-plugin to $file"
    return 0
  fi
  mkdir -p "$dir"
  if [ ! -f "$file" ] || ! cmp -s "$template" "$file"; then
    cp "$template" "$file"
    log "  Synced inbound event bridge mu-plugin: $file"
    [ -z "${UPDATED_ITEMS+x}" ] || UPDATED_ITEMS+=("Inbound event bridge")
  fi
  service_file_normalize_perms "$file"
}
