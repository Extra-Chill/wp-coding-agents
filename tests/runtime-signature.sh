#!/bin/bash
# tests/runtime-signature.sh — Regression coverage for lib/runtime-signature.sh.
#
# Asserts:
#   1. Fresh scaffold writes a syntactically-valid PHP mu-plugin that wires
#      add_filter( 'datamachine_code_worktree_runtime_signatures', … ).
#   2. Register is idempotent — re-running with the same signature does not
#      mutate the file.
#   3. Re-registering with a different signature replaces just that runtime's
#      block, leaving other runtimes' blocks intact.
#   4. Unregister removes a runtime's block without touching siblings.
#   5. After register × 2 + unregister × 1 the file still parses with `php -l`
#      and applying the filter returns the surviving signature.
#
# The PHP-execution assertion (step 5) uses a tiny shim that stubs the
# WordPress filter primitives so the mu-plugin can run outside a real WP
# install. It validates the *shape* of the data DMC#416 will consume, not
# the WP runtime integration itself.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/wp-content/mu-plugins"
export SITE_PATH="$TMP"
export DRY_RUN=false

# Silence helper logs in test output unless --verbose is passed.
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
  esac
done

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/runtime-signature.sh"
UPDATED_ITEMS=()

if [ "$VERBOSE" = false ]; then
  log() { :; }
  warn() { echo "WARN: $1" >&2; }
fi

MU_FILE="$TMP/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
FAILED=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: $want"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [ -f "$file" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name (missing: $file)"
    FAILED=$((FAILED + 1))
  fi
}

assert_php_lint() {
  local file="$1" name="$2"
  if php -l "$file" >/dev/null 2>&1; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    php -l "$file" 2>&1 | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
}

file_hash() {
  local file="$1"
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$file" | cut -d' ' -f1
  else
    md5 -q "$file"
  fi
}

file_mode() {
  local file="$1"
  if stat -c %a "$file" >/dev/null 2>&1; then
    stat -c %a "$file"
  else
    stat -f %Lp "$file"
  fi
}

assert_mode_0644() {
  local file="$1" name="$2"
  local got
  got=$(file_mode "$file")
  if [ "$got" = "644" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: 644"
    FAILED=$((FAILED + 1))
  fi
}

# --- 1. Fresh scaffold + register opencode ---------------------------------
# Use a hostile umask (matches root cron/systemd default 0077) to prove the
# helper forces 0644 regardless of caller umask — see issue #133.
echo "==> register opencode (fresh scaffold, umask 077)"
(
  umask 077
  runtime_signature_register "opencode" \
    '{"run_id":"OPENCODE_RUN_ID"}'
)
assert_file_exists "$MU_FILE" "mu-plugin created"
assert_php_lint "$MU_FILE" "scaffold parses with php -l"
assert_mode_0644 "$MU_FILE" "mu-plugin mode 0644 after fresh write under umask 077"

if grep -q "BEGIN runtime:opencode" "$MU_FILE"; then
  echo "  ok   opencode block present"
else
  echo "  FAIL opencode block missing"
  FAILED=$((FAILED + 1))
fi

if grep -q "OPENCODE_SESSION_ID\|KIMAKI_SESSION_ID\|KIMAKI_THREAD_ID\|KIMAKI_THREAD_URL" "$MU_FILE"; then
  echo "  FAIL stale unsupported env vars registered"
  FAILED=$((FAILED + 1))
else
  echo "  ok   stale unsupported env vars absent"
fi

# --- 2. Idempotency --------------------------------------------------------
echo "==> re-register opencode with same signature (idempotent)"
HASH_BEFORE=$(file_hash "$MU_FILE")
runtime_signature_register "opencode" \
  '{"run_id":"OPENCODE_RUN_ID"}'
HASH_AFTER=$(file_hash "$MU_FILE")
assert_eq "$HASH_AFTER" "$HASH_BEFORE" "file unchanged on re-register"

# --- 3. Add a sibling runtime without disturbing opencode -------------------
# Simulate a legacy 0600 file from a pre-#133 install. The next register call
# must self-heal it back to 0644 via the mktemp+mv path.
echo "==> simulate legacy 0600 file and verify self-heal on next register"
chmod 0600 "$MU_FILE"
runtime_signature_register "example" \
  '{"session_id":"EXAMPLE_SESSION_ID"}'
assert_php_lint "$MU_FILE" "two-runtime file parses with php -l"
assert_mode_0644 "$MU_FILE" "mu-plugin mode self-healed to 0644 after sibling register"

if grep -q "BEGIN runtime:opencode" "$MU_FILE" && grep -q "BEGIN runtime:example" "$MU_FILE"; then
  echo "  ok   both runtime blocks present"
else
  echo "  FAIL opencode and/or example block missing after sibling register"
  FAILED=$((FAILED + 1))
fi

# --- 4. Mutation: replace opencode block, sibling untouched ----------------
echo "==> re-register opencode with mutated signature"
runtime_signature_register "opencode" \
  '{"run_id":"OPENCODE_RUN_ID","trace_id":"OPENCODE_TRACE_ID"}'
if grep -q "OPENCODE_TRACE_ID" "$MU_FILE"; then
  echo "  ok   opencode block updated"
else
  echo "  FAIL opencode block did not pick up new subkey"
  FAILED=$((FAILED + 1))
fi
if grep -q "EXAMPLE_SESSION_ID" "$MU_FILE"; then
  echo "  ok   sibling block preserved across opencode mutation"
else
  echo "  FAIL sibling block clobbered by opencode re-register"
  FAILED=$((FAILED + 1))
fi

# --- 5. Unregister stale kimaki block and sibling --------------------------
echo "==> simulate legacy kimaki block and unregister it"
runtime_signature_register "kimaki" \
  '{"session_id":"KIMAKI_SESSION_ID","thread_id":"KIMAKI_THREAD_ID","thread_url":"KIMAKI_THREAD_URL"}'
runtime_signature_unregister "kimaki"
if grep -q "KIMAKI_SESSION_ID\|KIMAKI_THREAD_ID\|KIMAKI_THREAD_URL" "$MU_FILE"; then
  echo "  FAIL stale kimaki vars present after unregister"
  FAILED=$((FAILED + 1))
else
  echo "  ok   stale kimaki vars absent after unregister"
fi
echo "==> unregister sibling"
runtime_signature_unregister "example"
if grep -q "BEGIN runtime:example" "$MU_FILE"; then
  echo "  FAIL sibling block still present after unregister"
  FAILED=$((FAILED + 1))
else
  echo "  ok   sibling block removed"
fi
if grep -q "BEGIN runtime:opencode" "$MU_FILE"; then
  echo "  ok   opencode block preserved across unregisters"
else
  echo "  FAIL opencode block clobbered by unregisters"
  FAILED=$((FAILED + 1))
fi
assert_php_lint "$MU_FILE" "post-unregister file parses with php -l"
assert_mode_0644 "$MU_FILE" "mu-plugin mode 0644 after unregister"

# --- 6. Filter-shape end-to-end (php execution) ----------------------------
echo "==> apply_filters returns the expected shape"
SHIM="$TMP/filter-shim.php"
cat > "$SHIM" <<PHP
<?php
define( 'ABSPATH', '/' );
\$GLOBALS['filters'] = [];
function add_filter( \$tag, \$callback, \$priority = 10 ) {
    \$GLOBALS['filters'][\$tag][] = \$callback;
}
function apply_filters( \$tag, \$value ) {
    foreach ( \$GLOBALS['filters'][\$tag] ?? [] as \$cb ) {
        \$value = \$cb( \$value );
    }
    return \$value;
}
require '$MU_FILE';
\$result = apply_filters( 'datamachine_code_worktree_runtime_signatures', [] );
echo json_encode( \$result );
PHP
RESULT=$(php "$SHIM")
EXPECTED='{"opencode":{"run_id":"OPENCODE_RUN_ID","trace_id":"OPENCODE_TRACE_ID"}}'
assert_eq "$RESULT" "$EXPECTED" "filter returns surviving opencode signature"

# --- Done ------------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all runtime-signature assertions passed"
