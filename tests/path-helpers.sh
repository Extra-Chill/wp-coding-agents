#!/bin/bash
# tests/path-helpers.sh — unit tests for _resolve_node_bin_dir and
# _compose_path_value in bridges/_dispatch.sh.
#
# These helpers compose the PATH baked into kimaki's launchd plist /
# systemd unit. Bug repro for nvm-managed installs: when KIMAKI_BIN points
# at a standalone shim (e.g. ~/.kimaki/bin/kimaki) whose dir does NOT contain
# `node`, plugins shelling out via #!/usr/bin/env node fail with
# "env: node: No such file or directory" because launchd inherits a
# minimal PATH. _resolve_node_bin_dir closes that gap; _compose_path_value
# keeps the rendered PATH free of duplicates and empties.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source bridges/_dispatch.sh

PASS=0
FAIL=0

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

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ---------------------------------------------------------------------------
# _compose_path_value — pure string composition, no filesystem
# ---------------------------------------------------------------------------
echo "==> _compose_path_value"

assert_eq "single dir" \
  "/opt/bin" \
  "$(_compose_path_value /opt/bin)"

assert_eq "two distinct dirs" \
  "/opt/bin:/usr/bin" \
  "$(_compose_path_value /opt/bin /usr/bin)"

assert_eq "drops duplicate (npm-global case: kimaki and node share dir)" \
  "/usr/bin:/bin" \
  "$(_compose_path_value /usr/bin /usr/bin /bin)"

assert_eq "drops empty entries (no node found)" \
  "/opt/kimaki/bin:/usr/bin:/bin" \
  "$(_compose_path_value /opt/kimaki/bin "" /usr/bin /bin)"

assert_eq "preserves first-occurrence order" \
  "/a:/b:/c" \
  "$(_compose_path_value /a /b /c /a /b)"

assert_eq "all empty" \
  "" \
  "$(_compose_path_value "" "" "")"

# ---------------------------------------------------------------------------
# _resolve_node_bin_dir — depends on filesystem state
# ---------------------------------------------------------------------------
echo "==> _resolve_node_bin_dir"

# Build a fake nvm-style layout: shim at .kimaki/bin/kimaki that exec's
# a node that lives elsewhere (e.g. ~/.nvm/versions/node/v24/bin/node).
NVM_BIN_DIR="$TMPDIR_TEST/nvm/versions/node/v24/bin"
KIMAKI_SHIM_DIR="$TMPDIR_TEST/kimaki/bin"
mkdir -p "$NVM_BIN_DIR" "$KIMAKI_SHIM_DIR"

# Fake node — must be executable so `[ -x ]` passes.
cat > "$NVM_BIN_DIR/node" <<'EOF'
#!/bin/sh
echo "fake node"
EOF
chmod +x "$NVM_BIN_DIR/node"

# Fake kimaki shim — same shape as the real one (exec '<node>' … '<entrypoint>')
cat > "$KIMAKI_SHIM_DIR/kimaki" <<EOF
#!/bin/sh
exec '$NVM_BIN_DIR/node' '--heapsnapshot-near-heap-limit=3' '$NVM_BIN_DIR/kimaki' "\$@"
EOF
chmod +x "$KIMAKI_SHIM_DIR/kimaki"

# Test 1: kimaki shim resolution path. Force `command -v node` to miss by
# stripping PATH so the helper falls back to parsing the shim.
saved_path="$PATH"
PATH="/nonexistent"
assert_eq "follows kimaki shim when no node on PATH (nvm case)" \
  "$NVM_BIN_DIR" \
  "$(_resolve_node_bin_dir "$KIMAKI_SHIM_DIR/kimaki")"
PATH="$saved_path"

# Test 2: command -v wins when node IS on PATH.
PATH="$NVM_BIN_DIR:$saved_path"
assert_eq "uses command -v when node is on PATH" \
  "$NVM_BIN_DIR" \
  "$(_resolve_node_bin_dir "$KIMAKI_SHIM_DIR/kimaki")"
PATH="$saved_path"

# Test 3: missing shim, no node on PATH → empty.
PATH="/nonexistent"
assert_eq "empty when no node anywhere" \
  "" \
  "$(_resolve_node_bin_dir "/no/such/kimaki")"
PATH="$saved_path"

# Test 4: shim that exec's a non-existent node → empty (passes -x check).
BROKEN_SHIM="$TMPDIR_TEST/broken/kimaki"
mkdir -p "$(dirname "$BROKEN_SHIM")"
cat > "$BROKEN_SHIM" <<'EOF'
#!/bin/sh
exec '/no/such/node' '/no/such/kimaki.js' "$@"
EOF
chmod +x "$BROKEN_SHIM"
PATH="/nonexistent"
assert_eq "empty when shim references missing node binary" \
  "" \
  "$(_resolve_node_bin_dir "$BROKEN_SHIM")"
PATH="$saved_path"

# Test 5: no hint argument at all — relies on `command -v node` only.
PATH="$NVM_BIN_DIR:$saved_path"
assert_eq "no-hint: uses command -v" \
  "$NVM_BIN_DIR" \
  "$(_resolve_node_bin_dir)"
PATH="$saved_path"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"
  exit 1
fi
echo "OK: $PASS / $PASS assertions passed"
