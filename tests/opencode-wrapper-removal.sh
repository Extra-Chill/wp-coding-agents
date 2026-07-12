#!/bin/bash
# tests/opencode-wrapper-removal.sh — regression for #117 cleanup.
#
# wp-coding-agents previously installed a `wp-coding-agents-opencode-wrapper-v2`
# bash shim at the global `opencode` binary path on every Kimaki VPS upgrade.
# That whole integration was retired (Kimaki ships its own AnthropicAuthPlugin
# and non-kimaki bridges use opencode's native auth). The runtime now only
# removes legacy wrappers — it must never re-install one. These tests pin
# both behaviors.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0

log() { :; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       expected: '$expected'"
    echo "       actual:   '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_file_absent() {
  local label="$1" file="$2"
  if [ ! -e "$file" ]; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label (expected absent: $file)"
    FAIL=$((FAIL+1))
  fi
}

assert_file_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF "$needle" "$file"; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       expected $file to contain: $needle"
    FAIL=$((FAIL+1))
  fi
}

assert_file_lacks() {
  local label="$1" file="$2" needle="$3"
  if ! grep -qF "$needle" "$file"; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       did not expect $file to contain: $needle"
    FAIL=$((FAIL+1))
  fi
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source runtimes/opencode.sh
UPDATED_ITEMS=()

make_real_opencode() {
  local real_dir="$TMPDIR_TEST/real/bin"
  mkdir -p "$real_dir"
  cat > "$real_dir/.opencode" <<'EOF'
#!/bin/sh
echo real opencode "$@"
EOF
  chmod +x "$real_dir/.opencode"
  printf '%s/.opencode' "$real_dir"
}

make_legacy_wrapper() {
  local wrapper="$1" real_bin="$2"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# wp-coding-agents-opencode-wrapper-v2
set -euo pipefail
exec "$real_bin" "\$@"
EOF
  chmod +x "$wrapper"
}

echo "==> legacy wrapper is removed and real binary linked back"
REAL_BIN="$(make_real_opencode)"
BIN_DIR="$TMPDIR_TEST/bin"
mkdir -p "$BIN_DIR"
LEGACY_WRAPPER="$BIN_DIR/opencode"
make_legacy_wrapper "$LEGACY_WRAPPER" "$REAL_BIN"
# Simulate stale .bak file from a prior upgrade run.
cp "$LEGACY_WRAPPER" "${LEGACY_WRAPPER}.bak.20240101000000"

CHAT_BRIDGE=kimaki
LOCAL_MODE=false
DRY_RUN=false
PATH="$BIN_DIR:$PATH"

_remove_legacy_opencode_wrapper

assert_file_lacks "wrapper sentinel removed" "$LEGACY_WRAPPER" "wp-coding-agents-opencode-wrapper"
assert_file_absent "stale .bak file removed" "${LEGACY_WRAPPER}.bak.20240101000000"
assert_eq "global opencode runs the real binary" "real opencode" "$("$LEGACY_WRAPPER" 2>/dev/null | head -1)"

# Idempotent: running again on a clean (non-wrapper) binary is a no-op.
_remove_legacy_opencode_wrapper
assert_eq "rerun is idempotent" "real opencode" "$("$LEGACY_WRAPPER" 2>/dev/null | head -1)"

echo "==> non-wrapper binaries are never touched"
NON_WRAPPER_DIR="$TMPDIR_TEST/non-wrapper/bin"
mkdir -p "$NON_WRAPPER_DIR"
NON_WRAPPER="$NON_WRAPPER_DIR/opencode"
cat > "$NON_WRAPPER" <<'EOF'
#!/bin/sh
echo not-a-wrapper
EOF
chmod +x "$NON_WRAPPER"
NON_WRAPPER_HASH_BEFORE="$(cat "$NON_WRAPPER")"
PATH="$NON_WRAPPER_DIR:$PATH"
_remove_legacy_opencode_wrapper
assert_eq "non-wrapper binary untouched" "$NON_WRAPPER_HASH_BEFORE" "$(cat "$NON_WRAPPER")"

echo "==> repo no longer ships legacy install machinery"
assert_file_absent "lib/patch-claude-auth.py is gone" lib/patch-claude-auth.py
assert_file_lacks "runtimes/opencode.sh has no _install_opencode_wrapper" runtimes/opencode.sh "_install_opencode_wrapper"
assert_file_lacks "runtimes/opencode.sh has no _patch_claude_auth_plugin" runtimes/opencode.sh "_patch_claude_auth_plugin"
assert_file_lacks "runtimes/opencode.sh does not list opencode-claude-auth as a managed plugin" runtimes/opencode.sh '"opencode-claude-auth@latest"'
assert_file_lacks "lib/repair-opencode-json.py does not append opencode-claude-auth" lib/repair-opencode-json.py 'plugins.append("opencode-claude-auth@latest")'
assert_file_lacks "upgrade.sh has no reapply_claude_auth_patch" upgrade.sh "reapply_claude_auth_patch"
assert_file_contains "upgrade.sh wires the removal phase" upgrade.sh "remove_legacy_opencode_wrapper_phase"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"
  exit 1
fi
echo "OK: $PASS / $PASS assertions passed"
