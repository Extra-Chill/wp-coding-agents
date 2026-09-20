#!/usr/bin/env bash
# Generated backups must never remain in the public document root (#615).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/webroot-backup-hygiene.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }

# Legacy backups in the site root are removed; real files are untouched.
mkdir -p "$TMP/site"
touch "$TMP/site/AGENTS.md.backup.20250101-000000" \
      "$TMP/site/AGENTS.md.backup.20250102-000000" \
      "$TMP/site/opencode.json.backup.20250101-000000" \
      "$TMP/site/AGENTS.md" "$TMP/site/opencode.json" "$TMP/site/wp-config.php"
DRY_RUN=false webroot_backup_prune_legacy "$TMP/site" >/dev/null
check "legacy backups removed from site root" \
  "$(ls -1 "$TMP/site" | grep -c '\.backup\.' || true)" "0"
check "AGENTS.md preserved"   "$([ -f "$TMP/site/AGENTS.md" ] && echo y || echo n)" "y"
check "opencode.json preserved" "$([ -f "$TMP/site/opencode.json" ] && echo y || echo n)" "y"
check "wp-config.php preserved" "$([ -f "$TMP/site/wp-config.php" ] && echo y || echo n)" "y"

# Dry run reports without deleting.
touch "$TMP/site/AGENTS.md.backup.20250103-000000"
DRY_RUN=true webroot_backup_prune_legacy "$TMP/site" >/dev/null
check "dry run leaves legacy backups in place" \
  "$(ls -1 "$TMP/site" | grep -c '\.backup\.' || true)" "1"
DRY_RUN=false webroot_backup_prune_legacy "$TMP/site" >/dev/null

# Managed backups are bounded by keep-N, newest retained.
mkdir -p "$TMP/site/.wp-coding-agents/backups"
for i in 1 2 3 4 5 6 7; do
  touch "$TMP/site/.wp-coding-agents/backups/opencode.json.backup.2025010${i}-000000"
  sleep 0.01
done
WP_CODING_AGENTS_BACKUP_KEEP=3 DRY_RUN=false webroot_backup_prune_managed "$TMP/site"
check "managed backups bounded to keep-N" \
  "$(ls -1 "$TMP/site/.wp-coding-agents/backups" | wc -l | tr -d ' ')" "3"
check "newest managed backup retained" \
  "$([ -f "$TMP/site/.wp-coding-agents/backups/opencode.json.backup.20250107-000000" ] && echo y || echo n)" "y"

# Missing paths are a no-op, not an error.
webroot_backup_prune_legacy "$TMP/nope" >/dev/null
webroot_backup_prune_managed "$TMP/nope" >/dev/null
check "absent site path is a no-op" "ok" "ok"

[ "$fail" -eq 0 ] || exit 1
echo "All webroot backup hygiene checks passed."
