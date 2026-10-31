#!/bin/bash
# Only AGENTS.md backups are managed after OpenCode retirement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/webroot-backup-hygiene.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log() { :; }
mkdir -p "$TMP/site/.wp-coding-agents/backups"
touch "$TMP/site/AGENTS.md.backup.old" "$TMP/site/AGENTS.md" "$TMP/site/opencode.json"
DRY_RUN=true
webroot_backup_prune_legacy "$TMP/site"
[ -f "$TMP/site/AGENTS.md.backup.old" ]
DRY_RUN=false
webroot_backup_prune_legacy "$TMP/site"
[ ! -e "$TMP/site/AGENTS.md.backup.old" ]
[ -f "$TMP/site/AGENTS.md" ]
[ -f "$TMP/site/opencode.json" ]
# No new OpenCode backups or config management.
webroot_backup_prune_managed "$TMP/site"
echo 'PASS: webroot backup hygiene'
