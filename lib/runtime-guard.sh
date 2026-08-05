#!/bin/bash
# lib/runtime-guard.sh — protect the agent runtime from admin-UI deactivation.
#
# On a managed install the site owner has wp-admin access and no reason to
# understand the plugins list. Deactivating Data Machine there costs them their
# assistant's memory and tools, with no obvious way back.
#
# This guards the ADMIN UI only. `wp plugin deactivate data-machine` stays
# available because that is the operator's recovery path. The accident happens
# in wp-admin; the recovery happens on the CLI. See #328.
#
# Deliberately NOT an mu-plugin move (#323): WordPress fatal-error recovery
# pauses a plugin that fatals and cannot do that for an mu-plugin, so relocating
# the runtime would turn a broken assistant into a white screen on a live site.
#
# Public surface:
#   runtime_guard_mu_plugin_path
#   runtime_guard_sync            # installs under managed, removes otherwise
#
# Honors DRY_RUN (logs intent, makes no changes).

runtime_guard_mu_plugin_path() {
  if [ -z "${SITE_PATH:-}" ]; then
    return 1
  fi
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtime-guard.php"
}

# Plugin basenames to protect, one per line.
#
# `data-machine` is guarded unconditionally because wp-coding-agents installs it
# on every agent install — it is a property of the product, not of one site.
# Companions vary per install, so they are DISCOVERED from what is actually
# active rather than assumed. Naming a stack this tool has not inspected is the
# #320 mistake.
runtime_guard_plugins() {
  if [ "${DRY_RUN:-false}" = true ] || [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    printf '%s\n' 'data-machine/data-machine.php'
    return 0
  fi

  local discovered
  discovered="$(wp_cmd eval 'foreach ( (array) get_option( "active_plugins", array() ) as $p ) { if ( 0 === strpos( $p, "data-machine" ) ) { echo $p, "\n"; } }' 2>/dev/null || true)"

  if [ -z "$discovered" ]; then
    printf '%s\n' 'data-machine/data-machine.php'
    return 0
  fi

  printf '%s\n' "$discovered" | tr -d '\r' | sed '/^$/d' | sort -u
}

runtime_guard_sync() {
  local file
  file="$(runtime_guard_mu_plugin_path)" || {
    warn "  runtime_guard_sync: SITE_PATH not set — skipping"
    return 1
  }

  # Engineering installs have a developer at the keyboard; the guard would be
  # noise. Remove any guard left behind by a source-mode switch.
  if ! source_policy_is_owned; then
    if [ -f "$file" ]; then
      if [ "${DRY_RUN:-false}" = true ]; then
        echo -e "${BLUE}[dry-run]${NC} Would remove runtime guard mu-plugin $file"
        return 0
      fi
      rm -f "$file"
      log "  Removed runtime guard mu-plugin (source mode is ${SOURCE_MODE:-workspace}): $file"
      if [ -n "${UPDATED_ITEMS+x}" ]; then
        UPDATED_ITEMS+=("runtime guard removed")
      fi
    fi
    return 0
  fi

  local template="$SCRIPT_DIR/templates/wp-coding-agents-runtime-guard.php"
  if [ ! -f "$template" ]; then
    warn "  runtime_guard_sync: missing template $template"
    return 1
  fi

  local entries=""
  local plugin
  while IFS= read -r plugin; do
    [ -n "$plugin" ] || continue
    entries="${entries}		'$(printf '%s' "$plugin" | sed "s/'/\\\\'/g")',"$'\n'
  done < <(runtime_guard_plugins)

  if [ -z "$entries" ]; then
    warn "  runtime_guard_sync: no runtime plugins resolved — not writing an empty guard"
    return 1
  fi

  local rendered
  rendered="$(RUNTIME_GUARD_ENTRIES="$entries" python3 - "$template" <<'PY'
import os, pathlib, sys
template = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
begin = "\t\t// BEGIN wp-coding-agents-guarded-plugins\n"
end = "\t\t// END wp-coding-agents-guarded-plugins"
start = template.index(begin) + len(begin)
stop = template.index(end)
sys.stdout.write(template[:start] + os.environ["RUNTIME_GUARD_ENTRIES"] + template[stop:])
PY
)" || {
    warn "  runtime_guard_sync: could not render guard template"
    return 1
  }

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install runtime guard mu-plugin at $file guarding:"
    printf '%s' "$entries" | sed 's/^/    /'
    return 0
  fi

  local dir="${file%/*}"
  mkdir -p "$dir"

  if [ -f "$file" ] && printf '%s\n' "$rendered" | cmp -s - "$file"; then
    service_file_normalize_perms "$file"
    return 0
  fi

  printf '%s\n' "$rendered" > "$file"
  service_file_normalize_perms "$file"
  log "  Installed runtime guard mu-plugin: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("runtime deactivation guard")
  fi
}
