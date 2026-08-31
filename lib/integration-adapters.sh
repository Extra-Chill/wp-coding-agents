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
    local source_dir slug target_dir
    for source_dir in "${SCRIPT_DIR:-.}/carried-plugins"/*; do
      [ -d "$source_dir" ] || continue
      slug="${source_dir##*/}"
      target_dir="$site_path/wp-content/plugins/$slug"
      if carried_plugin_should_install "$slug" || carried_plugin_is_managed "$target_dir"; then
        INTEGRATION_ADAPTER_RECORDS+=("integrations.carried-plugin.$slug")
      fi
    done
  fi

  # The adapter also owns absence cleanup, including stale WordPress
  # availability state after Homeboy is disabled or removed.
  INTEGRATION_ADAPTER_RECORDS+=("integrations.homeboy")
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
  [ "${DRY_RUN:-false}" = true ] && return 0
  local source_dir slug target_dir
  for source_dir in "${SCRIPT_DIR:-.}/carried-plugins"/*; do
    [ -d "$source_dir" ] || continue
    slug="${source_dir##*/}"
    target_dir="$SITE_PATH/wp-content/plugins/$slug"
    if carried_plugin_should_install "$slug"; then
      [ -d "$target_dir" ] || return 1
      wp_cmd plugin is-active "$slug" >/dev/null 2>&1 || return 1
      if [ "$slug" = wp-coding-agents-integration ]; then
        wp_cmd eval 'exit(false !== has_filter("wp_coding_agents_host_can_execute_processes", "WpCodingAgents\\Integration\\provide_process_execution_capability") && false !== has_filter("wp_coding_agents_host_has_writable_process_workspace", "WpCodingAgents\\Integration\\provide_writable_process_workspace_capability") && false !== has_filter("intelligence_host_has_shell", "WpCodingAgents\\Integration\\provide_intelligence_shell_capability") && false !== has_filter("intelligence_host_has_writable_content_directory", "WpCodingAgents\\Integration\\provide_intelligence_writable_content_capability") ? 0 : 1);' >/dev/null 2>&1 || return 1
      fi
    elif carried_plugin_is_managed "$target_dir"; then
      return 1
    fi
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
  local config availability_count
  [ "${DRY_RUN:-false}" = true ] && return 0
  case "${INSTALLATION_PROFILE_HOMEBOY_MODE:-${HOMEBOY_MODE:-auto}}" in
    disabled)
      availability_count="$(wp_cmd option list --search=datamachine_code_homeboy_available --format=count 2>/dev/null)" || return 1
      [ "$availability_count" = 0 ]
      return $?
      ;;
  esac
  command -v homeboy >/dev/null 2>&1 || {
    homeboy_required && return 1
    availability_count="$(wp_cmd option list --search=datamachine_code_homeboy_available --format=count 2>/dev/null)" || return 1
    [ "$availability_count" = 0 ]
    return $?
  }
  config="$(homeboy_run config show)" || return 1
  python3 -c 'import json,sys; result=json.load(sys.stdin); data=result.get("data", {}).get("config", result); providers=data.get("worktree_providers") or {}; raise SystemExit(not isinstance(providers, dict) or "dmc" in providers)' <<< "$config" || return 1
  homeboy_required && ! homeboy_wordpress_extension_ready && return 1
  if homeboy_wordpress_extension_ready; then
    [ "$(wp_cmd option get datamachine_code_homeboy_available 2>/dev/null)" = 1 ] || return 1
  else
    availability_count="$(wp_cmd option list --search=datamachine_code_homeboy_available --format=count 2>/dev/null)" || return 1
    [ "$availability_count" = 0 ] || return 1
  fi
  return 0
}
