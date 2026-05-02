#!/bin/bash
# tests/homeboy-components.sh — unit test for DMC workspace Homeboy component attachment.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/data-machine.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
DM_WORKSPACE_DIR="$TMP/workspace"
WP_CMD="wp"
DRY_RUN=false
mkdir -p "$SITE_PATH" "$DM_WORKSPACE_DIR"

cat > "$SITE_PATH/homeboy.json" <<'JSON'
{"id":"site-project"}
JSON

mkdir -p \
  "$DM_WORKSPACE_DIR/alpha" \
  "$DM_WORKSPACE_DIR/beta" \
  "$DM_WORKSPACE_DIR/alpha@feature" \
  "$DM_WORKSPACE_DIR/no-metadata"

cat > "$DM_WORKSPACE_DIR/alpha/homeboy.json" <<'JSON'
{"id":"alpha"}
JSON
cat > "$DM_WORKSPACE_DIR/beta/homeboy.json" <<'JSON'
{"id":"beta"}
JSON
cat > "$DM_WORKSPACE_DIR/alpha@feature/homeboy.json" <<'JSON'
{"id":"alpha-feature"}
JSON

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/homeboy" <<'SH'
#!/bin/sh
if [ "$1 $2 $3" = "project components attach-path" ]; then
  printf '%s|%s\n' "$4" "$5" >> "$HOMEBOY_ATTACH_LOG"
  exit 0
fi
exit 2
SH
chmod +x "$FAKE_BIN/homeboy"

HOMEBOY_ATTACH_LOG="$TMP/attached.log"
export HOMEBOY_ATTACH_LOG
PATH="$FAKE_BIN:$PATH"

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -qF "$needle" "$file"; then
    echo "FAIL: expected '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -qF "$needle" "$file"; then
    echo "FAIL: unexpected '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

sync_homeboy_project_components > "$TMP/output.log"

assert_contains "site-project|$DM_WORKSPACE_DIR/alpha" "$HOMEBOY_ATTACH_LOG"
assert_contains "site-project|$DM_WORKSPACE_DIR/beta" "$HOMEBOY_ATTACH_LOG"
assert_not_contains "alpha@feature" "$HOMEBOY_ATTACH_LOG"
assert_not_contains "no-metadata" "$HOMEBOY_ATTACH_LOG"

assert_contains "skipped alpha@feature: worktree skipped" "$TMP/output.log"
assert_contains "skipped no-metadata: no homeboy.json" "$TMP/output.log"
assert_contains "Homeboy component sync complete: 2 attached, 2 skipped, 0 failed" "$TMP/output.log"

DRY_RUN=true
HOMEBOY_ATTACH_LOG="$TMP/dry-run-attached.log"
export HOMEBOY_ATTACH_LOG
sync_homeboy_project_components > "$TMP/dry-run-output.log"

if [ -f "$HOMEBOY_ATTACH_LOG" ]; then
  echo "FAIL: dry-run should not call homeboy attach-path"
  cat "$HOMEBOY_ATTACH_LOG"
  exit 1
fi
assert_contains "homeboy project components attach-path site-project $DM_WORKSPACE_DIR/alpha" "$TMP/dry-run-output.log"
assert_contains "homeboy project components attach-path site-project $DM_WORKSPACE_DIR/beta" "$TMP/dry-run-output.log"

echo "OK: Homeboy component attachment skips worktrees and metadata-less repos"
