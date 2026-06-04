#!/bin/bash
# tests/wp-codebox-subtree.sh — unit test for the WP Codebox subtree updater.
#
# Verifies the drift-prevention helper without touching the network: a stubbed
# `git ls-remote` provides the latest tag, and the test asserts the helper's
# decisions (skip when not installed, no-op when already current, sync when
# behind, delegate when it is a real git checkout).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wp-codebox.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Minimal harness state + stubs the helper depends on. -------------------
BLUE=""
NC=""
DRY_RUN=false
INSTALL_DATA_MACHINE=true
declare -a UPDATED_ITEMS=()
declare -a LOG_LINES=()

log()  { LOG_LINES+=("$*"); }
warn() { LOG_LINES+=("WARN: $*"); }
fix_ownership() { :; }
activate_plugin() { :; }
update_plugin_to_latest_tag() { LOG_LINES+=("DELEGATED: $1"); }

logged_contains() {
  local needle="$1"
  local line
  for line in "${LOG_LINES[@]}"; do
    case "$line" in
      *"$needle"*) return 0 ;;
    esac
  done
  return 1
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# Stub git: only `git ls-remote --tags ...` is used for tag resolution here.
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/git" <<'SH'
#!/bin/bash
if [ "$1" = "ls-remote" ]; then
  # Emit a couple of refs; helper takes the highest via sort -V.
  printf 'abc\trefs/tags/v0.4.0\n'
  printf 'def\trefs/tags/v0.5.0\n'
  exit 0
fi
# Any clone/sparse-checkout in these tests is unexpected; make it loud.
echo "unexpected git invocation: $*" >&2
exit 1
SH
chmod +x "$FAKE_BIN/git"
PATH="$FAKE_BIN:$PATH"
export PATH

make_plugin_dir() {
  local version="$1"
  local dir="$TMP/site/wp-content/plugins/wp-codebox"
  rm -rf "$dir"
  mkdir -p "$dir/src"
  cat > "$dir/wp-codebox.php" <<PHP
<?php
/**
 * Plugin Name: WP Codebox
 * Version: ${version}
 */
PHP
  echo "$dir"
}

# --- Case 1: not installed → skip cleanly. ----------------------------------
SITE_PATH="$TMP/empty-site"
mkdir -p "$SITE_PATH/wp-content/plugins"
LOG_LINES=()
update_wp_codebox_plugin_subtree
logged_contains "not installed" || fail "Case 1: expected not-installed skip"

# --- Case 2: installed and already at latest (0.5.0) → no-op. ----------------
SITE_PATH="$TMP/site"
make_plugin_dir "0.5.0" >/dev/null
LOG_LINES=()
update_wp_codebox_plugin_subtree
logged_contains "already at latest tag (v0.5.0)" || fail "Case 2: expected already-at-latest no-op"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "Case 2: must not record an update when current"

# --- Case 3: real git checkout → delegate to update_plugin_to_latest_tag. -----
SITE_PATH="$TMP/site"
plugin_dir="$(make_plugin_dir "0.4.0")"
mkdir -p "$plugin_dir/.git"
LOG_LINES=()
update_wp_codebox_plugin_subtree
logged_contains "DELEGATED: wp-codebox" || fail "Case 3: expected delegation for a git checkout"
rm -rf "$plugin_dir/.git"

# --- Case 4: behind + dry-run → reports the intended sync, performs no write. -
# Dry-run lines are emitted to stdout (echo), matching the codebase convention,
# so capture stdout rather than the log buffer for this case.
SITE_PATH="$TMP/site"
make_plugin_dir "0.4.0" >/dev/null
DRY_RUN=true
UPDATED_ITEMS=()
case4_out="$(update_wp_codebox_plugin_subtree)"
case "$case4_out" in
  *"0.4.0 → 0.5.0"*) : ;;
  *) fail "Case 4: expected dry-run to report 0.4.0 → 0.5.0 (got: $case4_out)" ;;
esac
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || fail "Case 4: dry-run must not record an update"
DRY_RUN=false

# --- Case 5: --no-data-machine equivalent (INSTALL_DATA_MACHINE=false) skips. -
SITE_PATH="$TMP/site"
make_plugin_dir "0.4.0" >/dev/null
INSTALL_DATA_MACHINE=false
LOG_LINES=()
update_wp_codebox_plugin_subtree
[ "${#LOG_LINES[@]}" -eq 0 ] || fail "Case 5: expected a clean skip when Data Machine install is disabled"
INSTALL_DATA_MACHINE=true

echo "wp-codebox-subtree tests passed"
