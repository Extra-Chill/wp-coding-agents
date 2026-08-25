#!/bin/bash
# WP Codebox: subtree-aware plugin updates.
#
# WP Codebox is not a standalone single-repo plugin — it lives in the
# `packages/wordpress-plugin/` subtree of a Node monorepo
# (Automattic/wp-codebox). The generic update_plugin_to_latest_tag() helper
# clones a whole repo into wp-content/plugins/<slug> and checks out a tag, which
# would deposit the entire monorepo (not just the plugin) and never works for a
# subtree-packaged plugin. As a result a WP Codebox install made from the
# packaged subtree is NOT a git checkout, so update_plugin_to_latest_tag() skips
# it and the install silently drifts behind upstream tags.
#
# This helper closes that gap: it sparse-checks-out the wordpress-plugin subtree
# at the latest version tag and syncs it into wp-content/plugins/wp-codebox,
# preserving the artifact-install shape (no .git in the plugin dir) while keeping
# it current. It is a no-op unless WP Codebox is already installed (we do not
# install it here — that remains the setup interview's job).

WP_CODEBOX_REPO_URL="${WP_CODEBOX_REPO_URL:-https://github.com/Automattic/wp-codebox.git}"
WP_CODEBOX_PLUGIN_SUBTREE="${WP_CODEBOX_PLUGIN_SUBTREE:-packages/wordpress-plugin}"

# Resolve the latest version tag from the remote without a full clone.
_wp_codebox_latest_tag() {
  local refs="${1:-}"
  if [ -z "$refs" ]; then
    refs="$(git ls-remote --tags --refs "$WP_CODEBOX_REPO_URL" 2>/dev/null)"
  fi
  printf '%s\n' "$refs" \
    | awk -F/ '{print $NF}' \
    | grep -E '^v?[0-9]' \
    | sort -V \
    | tail -n 1
}

_wp_codebox_fail() {
  warn "$1"
  [ "${PLUGIN_UPDATE_ACTIVE:-false}" != true ]
}

_wp_codebox_sync_files() {
  local src="$1" plugin_dir="$2"
  rm -rf "$plugin_dir/src"
  cp -a "$src/src" "$plugin_dir/src"
  [ -d "$src/assets" ] && { rm -rf "$plugin_dir/assets"; cp -a "$src/assets" "$plugin_dir/assets"; }
  cp -a "$src/wp-codebox.php" "$plugin_dir/wp-codebox.php"
  [ ! -f "$src/README.md" ] || cp -a "$src/README.md" "$plugin_dir/README.md"
  [ ! -f "$src/package.json" ] || cp -a "$src/package.json" "$plugin_dir/package.json"
}

# Read the Version: header from a plugin main file.
_wp_codebox_header_version() {
  local main_file="$1"
  [ -f "$main_file" ] || return 1
  grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' "$main_file" \
    | sed -E 's/.*Version:[[:space:]]*([0-9][0-9.]*).*/\1/'
}

update_wp_codebox_plugin_subtree() {
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    return 0
  fi

  local plugin_dir="$SITE_PATH/wp-content/plugins/wp-codebox"

  if [ ! -d "$plugin_dir" ]; then
    log "WP Codebox not installed — skipping subtree update"
    return 0
  fi

  # If it IS a git checkout, the generic tagged-release path already handles it;
  # don't double-manage.
  if [ -d "$plugin_dir/.git" ]; then
    update_plugin_to_latest_tag wp-codebox "$WP_CODEBOX_REPO_URL"
    return 0
  fi

  local latest_tag
  if declare -F plugin_update_run_phase >/dev/null 2>&1; then
    if plugin_update_run_phase wp-codebox tag-discovery git ls-remote --tags --refs "$WP_CODEBOX_REPO_URL"; then
      latest_tag="$(_wp_codebox_latest_tag "$PLUGIN_PHASE_OUTPUT")"
    else
      local phase_status=$?
      _wp_codebox_fail "Could not resolve latest WP Codebox tag — copied install unchanged"
      return "$phase_status"
    fi
  else
    latest_tag="$(_wp_codebox_latest_tag)"
  fi
  if [ -z "$latest_tag" ]; then
    _wp_codebox_fail "Could not resolve latest WP Codebox tag — copied install unchanged"
    return $?
  fi

  local current_version
  current_version="$(_wp_codebox_header_version "$plugin_dir/wp-codebox.php" || echo "")"
  local target_version="${latest_tag#v}"

  if [ -n "$current_version" ] && [ "$current_version" = "$target_version" ]; then
    log "WP Codebox already at latest tag ($latest_tag)"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Sparse-checkout ${WP_CODEBOX_PLUGIN_SUBTREE} at ${latest_tag} and sync into ${plugin_dir}"
    echo -e "${BLUE}[dry-run]${NC} WP Codebox ${current_version:-unknown} → ${target_version}"
    return 0
  fi

  log "Updating WP Codebox: ${current_version:-unknown} → ${target_version} (subtree sync)"

  local staging
  staging="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" RETURN

  if plugin_update_run_phase wp-codebox release-clone git clone --depth 1 --branch "$latest_tag" --filter=blob:none --sparse \
      "$WP_CODEBOX_REPO_URL" "$staging/repo"; then
    :
  else
    local phase_status=$?
    _wp_codebox_fail "Could not clone WP Codebox at ${latest_tag} — copied install unchanged"
    return "$phase_status"
  fi

  if plugin_update_run_phase wp-codebox sparse-checkout git -C "$staging/repo" sparse-checkout set "$WP_CODEBOX_PLUGIN_SUBTREE"; then
    :
  else
    local phase_status=$?
    _wp_codebox_fail "Could not sparse-checkout ${WP_CODEBOX_PLUGIN_SUBTREE} — copied install unchanged"
    return "$phase_status"
  fi

  local src="$staging/repo/$WP_CODEBOX_PLUGIN_SUBTREE"
  if [ ! -f "$src/wp-codebox.php" ]; then
    _wp_codebox_fail "WP Codebox plugin subtree missing wp-codebox.php at ${latest_tag} — copied install unchanged"
    return $?
  fi

  if plugin_update_run_phase wp-codebox subtree-sync _wp_codebox_sync_files "$src" "$plugin_dir"; then
    :
  else
    local phase_status=$?
    return "$phase_status"
  fi
  plugin_update_run_phase wp-codebox ownership-normalization fix_ownership "$plugin_dir" || return $?

  UPDATED_ITEMS+=("wp-codebox $latest_tag")
}
