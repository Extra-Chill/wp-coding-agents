#!/bin/bash
# lib/site-identity-guard.sh — protect the agent home site in every source mode.
# Honors DRY_RUN (logs intent, makes no changes).
# Public surface: site_identity_guard_mu_plugin_path, site_identity_guard_sync.

site_identity_guard_mu_plugin_path() {
  [ -n "${SITE_PATH:-}" ] || return 1
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-site-identity-guard.php"
}

site_identity_guard_sync() {
  local file template
  file="$(site_identity_guard_mu_plugin_path)" || {
    warn "  site_identity_guard_sync: SITE_PATH not set — skipping"
    return 1
  }
  template="$SCRIPT_DIR/templates/wp-coding-agents-site-identity-guard.php"
  if [ ! -f "$template" ]; then
    warn "  site_identity_guard_sync: missing template $template"
    return 1
  fi
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install site identity guard mu-plugin at $file"
    return 0
  fi

  mkdir -p "${file%/*}"
  if [ -f "$file" ] && cmp -s "$template" "$file"; then
    service_file_normalize_perms "$file"
    return 0
  fi
  cp "$template" "$file"
  service_file_normalize_perms "$file"
  log "  Installed site identity guard mu-plugin: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("site identity guard")
  fi
}
