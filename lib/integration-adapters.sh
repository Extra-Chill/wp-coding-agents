#!/bin/bash
# Optional integration policy projected through the desired-state reconciler.

integration_adapters_detect() {
  INTEGRATION_ADAPTER_RECORDS=()

  # External WordPress has no local site tree to mutate. Its runtime-local
  # repository and Homeboy setup are handled by the external runtime boundary.
  [ "${INSTALLATION_PROFILE_EXTERNAL_WORDPRESS:-false}" = true ] && return 0

  local site_path="${INSTALLATION_PROFILE_SITE_PATH:-${SITE_PATH:-}}"
  [ -n "$site_path" ] || return 0

  if [ -e "$site_path/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" ]; then
    INTEGRATION_ADAPTER_RECORDS+=("integrations.dmc-managed-release-cleanup")
  fi

  # A non-git DMC directory was copied by Homeboy. It is intentionally not a
  # wp-coding-agents release channel and must never be converted or updated.
  if [ -d "$site_path/wp-content/plugins/data-machine-code" ] && \
     [ ! -d "$site_path/wp-content/plugins/data-machine-code/.git" ]; then
    INTEGRATION_ADAPTER_RECORDS+=("integrations.dmc-copied-release")
  fi

  if [ -d "${SCRIPT_DIR:-.}/carried-plugins" ] && \
     declare -F carried_plugin_should_install >/dev/null 2>&1; then
    local source_dir slug
    for source_dir in "${SCRIPT_DIR:-.}/carried-plugins"/*; do
      [ -d "$source_dir" ] || continue
      slug="${source_dir##*/}"
      if carried_plugin_should_install "$slug"; then
        INTEGRATION_ADAPTER_RECORDS+=("integrations.carried-plugin.$slug")
      fi
    done
  fi

  case "${INSTALLATION_PROFILE_HOMEBOY_MODE:-${HOMEBOY_MODE:-auto}}" in
    disabled) ;;
    enabled) INTEGRATION_ADAPTER_RECORDS+=("integrations.homeboy") ;;
    *)
      if command -v homeboy >/dev/null 2>&1; then
        INTEGRATION_ADAPTER_RECORDS+=("integrations.homeboy")
      fi
      ;;
  esac
}

integration_adapters_plan() {
  declare -F reconciler_plan_add >/dev/null 2>&1 || {
    error "Integration adapters require the desired-state reconciler plan API"
    return 1
  }

  integration_adapters_detect
  local record carried_plugins_planned=false
  for record in "${INTEGRATION_ADAPTER_RECORDS[@]}"; do
    case "$record" in
      integrations.dmc-managed-release-cleanup)
        reconciler_plan_add "$record" integrations.dmc-managed-release-cleanup _integration_adapter_cleanup_managed_release _integration_adapter_verify_managed_release
        ;;
      integrations.dmc-copied-release)
        reconciler_plan_add "$record" integrations.dmc-copied-release _integration_adapter_preserve_copied_dmc _integration_adapter_verify_copied_dmc
        ;;
      integrations.carried-plugin.*)
        [ "$carried_plugins_planned" = false ] || continue
        reconciler_plan_add integrations.carried-plugins integrations.carried-plugin _integration_adapter_sync_carried_plugins _integration_adapter_verify_carried_plugins
        carried_plugins_planned=true
        ;;
      integrations.homeboy)
        reconciler_plan_add "$record" integrations.homeboy _integration_adapter_sync_homeboy _integration_adapter_verify_homeboy
        ;;
    esac
  done
}

integration_adapters_apply() {
  reconciler_apply_plan
}

integration_adapters_verify() {
  reconciler_verify_plan
}

_integration_adapter_cleanup_managed_release() {
  local file="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE:-}[dry-run]${NC:-} rm -f $file"
    return 0
  fi
  rm -f "$file"
  reconciler_adapter_changed
}

_integration_adapter_verify_managed_release() {
  [ ! -e "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php" ]
}

_integration_adapter_preserve_copied_dmc() {
  log "[data-machine-code] terminal=skipped reason=homeboy-copied-release"
}

_integration_adapter_verify_copied_dmc() {
  [ -d "$SITE_PATH/wp-content/plugins/data-machine-code" ] && \
    [ ! -d "$SITE_PATH/wp-content/plugins/data-machine-code/.git" ]
}

_integration_adapter_sync_carried_plugins() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  sync_carried_plugins || return $?
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

_integration_adapter_verify_carried_plugins() {
  local record slug
  for record in "${INTEGRATION_ADAPTER_RECORDS[@]}"; do
    case "$record" in
      integrations.carried-plugin.*)
        slug="${record##*.}"
        [ -d "$SITE_PATH/wp-content/plugins/$slug" ] || return 1
        ;;
    esac
  done
}

_integration_adapter_sync_homeboy() {
  local before=0
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && before="${#UPDATED_ITEMS[@]}"
  setup_homeboy_project || return $?
  configure_homeboy_worktree_ownership || return $?
  configure_homeboy_wordpress_extension || return $?
  declare -p UPDATED_ITEMS >/dev/null 2>&1 && [ "${#UPDATED_ITEMS[@]}" -gt "$before" ] && reconciler_adapter_changed
  return 0
}

_integration_adapter_verify_homeboy() {
  command -v homeboy >/dev/null 2>&1 || return 1
  if [ "${DRY_RUN:-false}" = true ]; then
    return 0
  fi
  ! homeboy_run config show /worktree_providers/dmc >/dev/null 2>&1
}
