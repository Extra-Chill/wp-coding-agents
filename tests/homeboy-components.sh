#!/bin/bash
# tests/homeboy-components.sh — unit test for DMC workspace Homeboy component attachment.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"
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
if [ "$1 $2" = "project show" ]; then
  cat "$HOMEBOY_PROJECT_SHOW_JSON"
  exit 0
fi
if [ "$1 $2 $3" = "project components remove" ]; then
  shift 3
  project_id="$1"
  shift
  printf '%s|%s\n' "$project_id" "$*" >> "$HOMEBOY_REMOVE_LOG"
  printf '{"success":true}\n'
  exit 0
fi
if [ "$1 $2 $3" = "project components attach-path" ]; then
  printf '%s|%s\n' "$4" "$5" >> "$HOMEBOY_ATTACH_LOG"
  exit 0
fi
exit 2
SH
chmod +x "$FAKE_BIN/homeboy"

cat > "$FAKE_BIN/sudo" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|-H)
      shift
      ;;
    -u)
      shift 2
      ;;
    env)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          *=*) export "$1"; shift ;;
          *) break ;;
        esac
      done
      exec "$@"
      ;;
    *)
      shift
      ;;
  esac
done

exit 2
SH
chmod +x "$FAKE_BIN/sudo"

HOMEBOY_ATTACH_LOG="$TMP/attached.log"
HOMEBOY_REMOVE_LOG="$TMP/removed.log"
HOMEBOY_PROJECT_SHOW_JSON="$TMP/project-show.json"
export HOMEBOY_ATTACH_LOG HOMEBOY_REMOVE_LOG HOMEBOY_PROJECT_SHOW_JSON
PATH="$FAKE_BIN:$PATH"

write_project_show_json() {
  cat > "$HOMEBOY_PROJECT_SHOW_JSON" <<JSON
{"success":true,"data":{"entity":{"components":[
  {"id":"alpha","local_path":"$DM_WORKSPACE_DIR/alpha"},
  {"id":"beta","local_path":"$DM_WORKSPACE_DIR/beta"},
  {"id":"alpha-feature","local_path":"$DM_WORKSPACE_DIR/alpha@feature"},
  {"id":"no-metadata","local_path":"$DM_WORKSPACE_DIR/no-metadata"},
  {"id":"external","local_path":"$TMP/external@repo"}
]}}}
JSON
}

write_project_show_json

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL: expected '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -qF -- "$needle" "$file"; then
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
assert_contains "site-project|alpha-feature no-metadata" "$HOMEBOY_REMOVE_LOG"
assert_not_contains "external" "$HOMEBOY_REMOVE_LOG"

assert_contains "pruned stale Homeboy component(s): alpha-feature no-metadata" "$TMP/output.log"
assert_contains "skipped alpha@feature: worktree skipped" "$TMP/output.log"
assert_contains "skipped no-metadata: no homeboy.json" "$TMP/output.log"
assert_contains "Homeboy component sync complete: 2 attached, 2 skipped, 0 failed" "$TMP/output.log"

DRY_RUN=true
HOMEBOY_ATTACH_LOG="$TMP/dry-run-attached.log"
HOMEBOY_REMOVE_LOG="$TMP/dry-run-removed.log"
export HOMEBOY_ATTACH_LOG HOMEBOY_REMOVE_LOG
sync_homeboy_project_components > "$TMP/dry-run-output.log"

if [ -f "$HOMEBOY_ATTACH_LOG" ]; then
  echo "FAIL: dry-run should not call homeboy attach-path"
  cat "$HOMEBOY_ATTACH_LOG"
  exit 1
fi
assert_contains "homeboy project components attach-path site-project $DM_WORKSPACE_DIR/alpha" "$TMP/dry-run-output.log"
assert_contains "homeboy project components attach-path site-project $DM_WORKSPACE_DIR/beta" "$TMP/dry-run-output.log"
assert_contains "homeboy project components remove site-project alpha-feature no-metadata" "$TMP/dry-run-output.log"
if [ -f "$HOMEBOY_REMOVE_LOG" ]; then
  echo "FAIL: dry-run should not call homeboy components remove"
  cat "$HOMEBOY_REMOVE_LOG"
  exit 1
fi

cat > "$SITE_PATH/homeboy.json" <<'JSON'
{}
JSON
DRY_RUN=false
HOMEBOY_ATTACH_LOG="$TMP/empty-id-attached.log"
HOMEBOY_REMOVE_LOG="$TMP/empty-id-removed.log"
export HOMEBOY_ATTACH_LOG HOMEBOY_REMOVE_LOG
sync_homeboy_project_components > "$TMP/empty-id-output.log"

if [ -f "$HOMEBOY_ATTACH_LOG" ]; then
  echo "FAIL: empty project id should not call homeboy attach-path"
  cat "$HOMEBOY_ATTACH_LOG"
  exit 1
fi
assert_contains "Homeboy project config not found at site root — skipping DMC component attachment" "$TMP/empty-id-output.log"

cat > "$SITE_PATH/homeboy.json" <<'JSON'
{"id":"site-project"}
JSON
DRY_RUN=false
SERVICE_USER="opencode"
SERVICE_HOME="$TMP/opencode-home"
WP_CODING_AGENTS_TEST_ASSUME_ROOT=true
HOMEBOY_ATTACH_LOG="$TMP/service-user-attached.log"
HOMEBOY_REMOVE_LOG="$TMP/service-user-removed.log"
SUDO_LOG="$TMP/sudo.log"
export HOMEBOY_ATTACH_LOG HOMEBOY_REMOVE_LOG SUDO_LOG SERVICE_USER SERVICE_HOME WP_CODING_AGENTS_TEST_ASSUME_ROOT

sync_homeboy_project_components > "$TMP/service-user-output.log"

assert_contains "site-project|alpha-feature no-metadata" "$HOMEBOY_REMOVE_LOG"
assert_contains "site-project|$DM_WORKSPACE_DIR/alpha" "$HOMEBOY_ATTACH_LOG"
assert_contains "site-project|$DM_WORKSPACE_DIR/beta" "$HOMEBOY_ATTACH_LOG"
assert_contains "-n -H -u opencode env HOME=$SERVICE_HOME" "$SUDO_LOG"
assert_contains "PATH=" "$SUDO_LOG"
assert_contains "homeboy project components remove site-project alpha-feature no-metadata" "$SUDO_LOG"
assert_contains "homeboy project components attach-path site-project $DM_WORKSPACE_DIR/alpha" "$SUDO_LOG"

echo "OK: Homeboy component attachment prunes stale worktrees and skips metadata-less repos"
