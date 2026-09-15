#!/bin/bash
# tests/install-source-managed-file-sync.sh - managed-file sync preserves what it replaces.
#
# Exercises lib/install-source.sh against a real temp filesystem and asserts the
# resulting bytes on disk. The behavior under test is the one that actually bit
# an operator: an upgrade silently overwrote a site's Claude Code auth plugin
# and the previous content was unrecoverable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/install-source.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DRY_RUN=false
UPDATED_ITEMS=()

fail() { echo "FAIL: $1" >&2; exit 1; }

src="$WORK/source.ts"
dest="$WORK/site/.opencode/plugins/managed.ts"
printf 'shipped-v2\n' >"$src"

# --- fresh install -----------------------------------------------------------
install_source_sync_managed_file "$src" "$dest" "managed plugin"

[ -f "$dest" ] || fail "fresh install did not create the destination"
[ "$(cat "$dest")" = "shipped-v2" ] || fail "fresh install wrote the wrong content"
[ "${#UPDATED_ITEMS[@]}" -eq 1 ] || fail "fresh install should report exactly one updated item"

# --- identical re-run is a no-op ---------------------------------------------
UPDATED_ITEMS=()
before="$(stat -f %m "$dest" 2>/dev/null || stat -c %Y "$dest")"
install_source_sync_managed_file "$src" "$dest" "managed plugin"
after="$(stat -f %m "$dest" 2>/dev/null || stat -c %Y "$dest")"

[ "$before" = "$after" ] || fail "identical re-run rewrote the destination"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "identical re-run should report no updated items"

# --- diverged destination is backed up, not destroyed ------------------------
UPDATED_ITEMS=()
printf 'operator-hand-edit\n' >"$dest"
install_source_sync_managed_file "$src" "$dest" "managed plugin"

[ "$(cat "$dest")" = "shipped-v2" ] || fail "diverged sync did not install the source content"

backup="$(find "$(dirname "$dest")" -name 'managed.ts.backup.*' | head -1)"
[ -n "$backup" ] || fail "diverged sync did not write a backup"
[ "$(cat "$backup")" = "operator-hand-edit" ] || fail "backup does not contain the replaced content"
[ "${#UPDATED_ITEMS[@]}" -eq 1 ] || fail "diverged sync should report exactly one updated item"
case "${UPDATED_ITEMS[0]}" in
  *"$backup"*) ;;
  *) fail "diverged sync did not report the backup path to the operator" ;;
esac

# --- dry run changes nothing -------------------------------------------------
UPDATED_ITEMS=()
printf 'operator-hand-edit-2\n' >"$dest"
DRY_RUN=true
install_source_sync_managed_file "$src" "$dest" "managed plugin" >/dev/null
DRY_RUN=false

[ "$(cat "$dest")" = "operator-hand-edit-2" ] || fail "dry run modified the destination"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "dry run should report no updated items"

# --- missing source is skipped, destination untouched ------------------------
install_source_sync_managed_file "$WORK/absent.ts" "$dest" "managed plugin" >/dev/null
[ "$(cat "$dest")" = "operator-hand-edit-2" ] || fail "missing source clobbered the destination"

echo "PASS: tests/install-source-managed-file-sync.sh"
