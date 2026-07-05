#!/bin/bash
# tests/agents-md-backup-retention.sh — AGENTS.md backup retention coverage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/agents-md-backups.sh"

log() { :; }
warn() { echo "WARN: $1" >&2; }

make_backup() {
  local name="$1" touch_time="$2"
  printf 'backup %s\n' "$name" > "$TMP/$name"
  touch -t "$touch_time" "$TMP/$name"
}

make_backup AGENTS.md.backup.20240101-000000 202001010000
make_backup AGENTS.md.backup.20240102-000000 202001010000
make_backup AGENTS.md.backup.20240103-000000 202001010000
make_backup AGENTS.md.backup.20240104-000000 202001010000
make_backup AGENTS.md.backup.20230101-000000 "$(date +%Y%m%d%H%M)"
make_backup AGENTS.md.backup.notes 202001010000

AGENTS_MD_BACKUP_KEEP=2 AGENTS_MD_BACKUP_MAX_AGE_DAYS=30 DRY_RUN=false agents_md_prune_backups "$TMP"

FAILED=0

assert_exists() {
  local file="$1" label="$2"
  if [ -e "$TMP/$file" ]; then
    echo "  ok   $label"
  else
    echo "  FAIL $label"
    FAILED=$((FAILED + 1))
  fi
}

assert_missing() {
  local file="$1" label="$2"
  if [ ! -e "$TMP/$file" ]; then
    echo "  ok   $label"
  else
    echo "  FAIL $label"
    FAILED=$((FAILED + 1))
  fi
}

echo "==> AGENTS.md backup retention"
assert_missing AGENTS.md.backup.20240101-000000 "old backup outside latest keep pruned"
assert_missing AGENTS.md.backup.20240102-000000 "second old backup outside latest keep pruned"
assert_exists AGENTS.md.backup.20240103-000000 "latest keep backup preserved"
assert_exists AGENTS.md.backup.20240104-000000 "newest keep backup preserved"
assert_exists AGENTS.md.backup.20230101-000000 "recent backup outside latest keep preserved"
assert_exists AGENTS.md.backup.notes "non-managed backup-like file preserved"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: AGENTS.md backup retention assertions passed"
