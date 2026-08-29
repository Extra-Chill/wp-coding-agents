#!/bin/bash
# lib/source-reconcile.sh — install the continuous owned-source reconciler.
#
# Derivation used to run only during upgrade.sh, which is enough for a plugin
# that already exists and useless for one the agent is about to write: it creates
# the directory and nothing recomputes anything until somebody SSHes in. "Build
# me a booking plugin" then ends in a support ticket, which is what managed
# hosting exists to remove.
#
# The mu-plugin this installs listens to WordPress's own plugin and theme
# lifecycle hooks and reconciles the owned set, the capture manifest, and the
# runtime edit permissions as the installed set changes.
#
# WHY THE DERIVATION MOVED INTO PHP
#
# It began in lib/owned-source-discovery.sh. Keeping it there and adding a PHP
# copy for the reactive path would be two implementations of the same safety
# rule, free to drift — the exact failure #336 and #337 removed from the capture
# path. PHP wins the tie because it is the only one of the two that can run from
# a WordPress hook, so the shell now DELEGATES to it and there is one answer.
#
# Public surface:
#   source_reconcile_mu_plugin_path
#   source_reconcile_sync              # install / remove the mu-plugin
#   source_reconcile_prepare_manifest_dir
#   source_reconcile_run               # invoke a reconcile now, via WP-CLI

source_reconcile_mu_plugin_path() {
  [ -n "${SITE_PATH:-}" ] || return 1
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-source-reconcile.php"
}

# The manifest lives outside the web root and is written by PHP, which runs as
# www-data. Setup creates it root-owned, so the reactive path silently could not
# write it — the reconcile would update the option and leave capture reading a
# stale file, which is precisely the drift the manifest exists to prevent.
source_reconcile_prepare_manifest_dir() {
  local key dir
  key="${SITE_DOMAIN:-}"
  [ -n "$key" ] || key="$(basename "${SITE_PATH:-}" 2>/dev/null)"
  [ -n "$key" ] || return 0
  dir="${SOURCE_POLICY_MANIFEST_ROOT:-/var/lib/wp-coding-agents}/$key"

  [ "${LOCAL_MODE:-false}" = true ] && return 0

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would make $dir writable by www-data"
    return 0
  fi

  mkdir -p "$dir" 2>/dev/null || return 0
  # Group-owned by www-data with group write: PHP writes the manifest, and the
  # read-only capture identity still reads it. Not world-writable, and outside
  # the docroot so it is not web-servable either.
  chown root:www-data "$dir" 2>/dev/null || true
  chmod 2775 "$dir" 2>/dev/null || true
}

source_reconcile_sync() {
  local file
  file="$(source_reconcile_mu_plugin_path)" || {
    warn "  source_reconcile_sync: SITE_PATH not set — skipping"
    return 1
  }

  # Workspace installs derive nothing: their editable set is empty by design and
  # their changes reach git through a workspace, not a harvest. Remove anything
  # a source-mode switch left behind.
  if ! source_policy_is_owned; then
    if [ -f "$file" ]; then
      if [ "${DRY_RUN:-false}" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would remove source reconcile mu-plugin $file"
        return 0
      fi
      rm -f "$file"
      log "  Removed source reconcile mu-plugin (source mode is ${SOURCE_MODE:-workspace})"
    fi
    return 0
  fi

  local template="$SCRIPT_DIR/templates/wp-coding-agents-source-reconcile.php"
  if [ ! -f "$template" ]; then
    warn "  source_reconcile_sync: missing template $template"
    return 1
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install source reconcile mu-plugin at $file"
    return 0
  fi

  source_reconcile_prepare_manifest_dir

  mkdir -p "${file%/*}"
  if [ -f "$file" ] && cmp -s "$template" "$file"; then
    service_file_normalize_perms "$file"
    return 0
  fi

  cp "$template" "$file"
  service_file_normalize_perms "$file"
  log "  Installed source reconcile mu-plugin: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("continuous source reconcile")
  fi
}

# Run a reconcile now, so an upgrade converges the same way a live change does.
#
# Delegates rather than deriving: the mu-plugin is the single implementation, and
# a second one here is the drift this design exists to avoid.
source_reconcile_run() {
  source_policy_is_owned || return 0
  [ -n "${SITE_PATH:-}" ] || return 0
  [ -f "$SITE_PATH/wp-config.php" ] || return 0

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would run an owned-source reconcile via WP-CLI"
    return 0
  fi

  local out
  out="$(wp_cmd eval 'if ( function_exists( "wp_coding_agents_reconcile_sources" ) ) { $r = wp_coding_agents_reconcile_sources( true ); echo $r["status"] . ( isset( $r["reason"] ) ? ": " . $r["reason"] : "" ); } else { echo "unavailable"; }' 2>/dev/null || true)"

  case "$out" in
    reconciled*) log "  Owned sources reconciled from site state" ;;
    unchanged*)  : ;;
    deferred*)   warn "  Owned-source reconcile deferred (${out#deferred: }) — the recorded set stands" ;;
    skipped*)    : ;;
    *)           warn "  Owned-source reconcile did not run: ${out:-no response}" ;;
  esac
}
