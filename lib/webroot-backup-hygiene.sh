#!/usr/bin/env bash
# Keep generated backups out of the public document root (#615).
#
# $SITE_PATH on a WordPress install is the served docroot. Older versions of
# there, where they are fetchable over HTTP. AGENTS.md rollback now uses a
# .wp-coding-agents/backups/. These helpers remove what earlier versions left
# behind and bound what the new location accumulates.

# Remove legacy backups this installer used to write into the site root.
webroot_backup_prune_legacy() {
  local site_path="$1"
  [ -n "$site_path" ] && [ -d "$site_path" ] || return 0

  local removed=0 f
  for f in "$site_path"/AGENTS.md.backup.*; do
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

# user-authored and repaired in place, so a durable backup is justified — but
# it should not grow without limit.
webroot_backup_prune_managed() { :; }
