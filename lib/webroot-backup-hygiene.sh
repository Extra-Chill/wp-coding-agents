#!/usr/bin/env bash
# Keep generated backups out of the public document root (#615).
#
# $SITE_PATH on a WordPress install is the served docroot. Older versions of
# this installer wrote AGENTS.md.backup.<ts> and opencode.json.backup.<ts>
# there, where they are fetchable over HTTP. AGENTS.md rollback now uses a
# temp file discarded on success, and opencode.json backups are written under
# .wp-coding-agents/backups/. These helpers remove what earlier versions left
# behind and bound what the new location accumulates.

# Remove legacy backups this installer used to write into the site root.
webroot_backup_prune_legacy() {
  local site_path="$1"
  [ -n "$site_path" ] && [ -d "$site_path" ] || return 0

  local removed=0 f
  for f in "$site_path"/AGENTS.md.backup.* "$site_path"/opencode.json.backup.*; do
    [ -e "$f" ] || continue
    if [ "${DRY_RUN:-false}" = true ]; then
      removed=$((removed + 1))
      continue
    fi
    rm -f "$f" 2>/dev/null && removed=$((removed + 1))
  done

  [ "$removed" -gt 0 ] || return 0
  if [ "${DRY_RUN:-false}" = true ]; then
    echo "  [dry-run] Would remove $removed legacy backup(s) from the site root"
  else
    echo "  Removed $removed legacy backup(s) from the site root (#615)"
  fi
}

# Bound the relocated opencode.json backups. Unlike AGENTS.md, opencode.json is
# user-authored and repaired in place, so a durable backup is justified — but
# it should not grow without limit.
webroot_backup_prune_managed() {
  local site_path="$1"
  local keep="${WP_CODING_AGENTS_BACKUP_KEEP:-5}"
  local dir="$site_path/.wp-coding-agents/backups"
  [ -n "$site_path" ] && [ -d "$dir" ] || return 0
  case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
  [ "${DRY_RUN:-false}" = true ] && return 0

  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -gt "$keep" ] && rm -f "$f" 2>/dev/null
  done < <(ls -1t "$dir"/*.backup.* 2>/dev/null)
}
