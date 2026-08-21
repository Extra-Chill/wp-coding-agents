#!/bin/bash
# tests/opencode-claude-auth-retired.sh — regression for #117.
#
# wp-coding-agents previously installed a `wp-coding-agents-opencode-wrapper-v2`
# bash shim at the global `opencode` binary path so the third-party
# opencode-claude-auth plugin could read Anthropic OAuth credentials. That whole
# integration was retired in #117 on 2026-05-03: Kimaki ships its own
# AnthropicAuthPlugin and non-kimaki bridges use opencode native auth.
#
# The upgrade-time strip that removed leftover wrappers is gone too. It could
# only fire on an install that had skipped every upgrade since May, so it was a
# check that ran forever and could never match.
#
# What remains worth pinning is the DECISION: the install machinery must never
# come back. These assertions are cheap, have no runtime dependencies, and fail
# loudly if someone reintroduces the plugin or its patcher.
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

echo "==> repo no longer ships legacy install machinery"
assert_file_absent "lib/patch-claude-auth.py is gone" lib/patch-claude-auth.py
assert_file_lacks "runtimes/opencode.sh has no _install_opencode_wrapper" runtimes/opencode.sh "_install_opencode_wrapper"
assert_file_lacks "runtimes/opencode.sh has no _patch_claude_auth_plugin" runtimes/opencode.sh "_patch_claude_auth_plugin"
assert_file_lacks "runtimes/opencode.sh does not list opencode-claude-auth as a managed plugin" runtimes/opencode.sh '"opencode-claude-auth@latest"'
assert_file_lacks "lib/repair-opencode-json.py does not append opencode-claude-auth" lib/repair-opencode-json.py 'plugins.append("opencode-claude-auth@latest")'
assert_file_lacks "upgrade.sh has no reapply_claude_auth_patch" upgrade.sh "reapply_claude_auth_patch"
assert_file_lacks "upgrade.sh no longer carries the wrapper-removal phase" upgrade.sh "remove_legacy_opencode_wrapper"
assert_file_lacks "runtimes/opencode.sh no longer defines the wrapper remover" runtimes/opencode.sh "_remove_legacy_opencode_wrapper"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"
  exit 1
fi
echo "OK: $PASS / $PASS assertions passed"
