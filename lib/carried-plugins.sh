#!/bin/bash
# Carried plugins: wp-coding-agents-owned WordPress plugins copied into installs.

carried_plugin_should_install() {
  local slug="$1"
  local desired
  for desired in "${INSTALLATION_PROFILE_CARRIED_PLUGINS[@]:-}"; do
    [ "$desired" = "$slug" ] && return 0
  done
  return 1
}

carried_plugin_is_managed() {
  [ -f "$1/.wp-coding-agents-carried" ]
}

sync_carried_plugins() {
  local source_root="$SCRIPT_DIR/carried-plugins"
  [ -d "$source_root" ] || return 0

  local source_dir slug target_dir
  for source_dir in "$source_root"/*; do
    [ -d "$source_dir" ] || continue
    slug=$(basename "$source_dir")

    target_dir="$SITE_PATH/wp-content/plugins/$slug"
    if ! carried_plugin_should_install "$slug"; then
      carried_plugin_is_managed "$target_dir" || continue
      log "Removing undesired carried plugin: $slug"
      if [ "$DRY_RUN" = true ]; then
        if [ "${MULTISITE:-false}" = true ]; then
          echo -e "${BLUE}[dry-run]${NC} $(wp_cli_transport_display) plugin deactivate $slug --network --path=$SITE_PATH $WP_ROOT_FLAG"
          echo -e "${BLUE}[dry-run]${NC} Would deactivate $slug on every multisite site before removal"
        fi
        echo -e "${BLUE}[dry-run]${NC} $(wp_cli_transport_display) plugin deactivate $slug --path=$SITE_PATH $WP_ROOT_FLAG"
        echo -e "${BLUE}[dry-run]${NC} rm -rf $target_dir"
        continue
      fi
      if [ "${MULTISITE:-false}" = true ]; then
        wp_cmd plugin deactivate "$slug" --network >/dev/null || return $?
        local site_urls site_url
        site_urls="$(wp_cmd site list --field=url)" || return $?
        while IFS= read -r site_url; do
          [ -n "$site_url" ] || continue
          wp_cmd plugin deactivate "$slug" --url="$site_url" >/dev/null || return $?
        done <<< "$site_urls"
      else
        wp_cmd plugin deactivate "$slug" >/dev/null || return $?
      fi
      rm -rf "$target_dir"
      if declare -p UPDATED_ITEMS >/dev/null 2>&1; then
        UPDATED_ITEMS+=("removed carried plugin $slug")
      fi
      continue
    fi

    log "Syncing carried plugin: $slug"

    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} mkdir -p $target_dir"
      echo -e "${BLUE}[dry-run]${NC} rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete $source_dir/ $target_dir/"
      echo -e "${BLUE}[dry-run]${NC} $(wp_cli_transport_display) plugin activate $slug --path=$SITE_PATH $WP_ROOT_FLAG"
      continue
    fi

    if [ -d "$target_dir/.git" ]; then
      warn "Carried plugin target $target_dir is a git checkout — skipping sync"
      continue
    fi

    mkdir -p "$target_dir"
    rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$source_dir/" "$target_dir/"
    activate_plugin "$slug"
    fix_ownership "$target_dir"

    if declare -p UPDATED_ITEMS >/dev/null 2>&1; then
      UPDATED_ITEMS+=("carried plugin $slug")
    fi
  done
}
