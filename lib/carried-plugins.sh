#!/bin/bash
# Carried plugins: wp-coding-agents-owned WordPress plugins copied into installs.

carried_plugin_should_install() {
  local slug="$1"

  case "$slug" in
    ai-provider-for-claude-code)
      for runtime in "${DETECTED_RUNTIMES[@]}"; do
        if [ "$runtime" = "claude-code" ]; then
          return 0
        fi
      done
      [ "${RUNTIME:-}" = "claude-code" ] && return 0
      return 1
      ;;
  esac

  return 1
}

sync_carried_plugins() {
  local source_root="$SCRIPT_DIR/carried-plugins"
  [ -d "$source_root" ] || return 0

  local source_dir slug target_dir
  for source_dir in "$source_root"/*; do
    [ -d "$source_dir" ] || continue
    slug=$(basename "$source_dir")

    if ! carried_plugin_should_install "$slug"; then
      continue
    fi

    target_dir="$SITE_PATH/wp-content/plugins/$slug"
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
