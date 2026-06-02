#!/bin/bash
# tests/agents-md-guidance.sh — Regression coverage for AGENTS.md guidance registry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/wp-content/mu-plugins"
export SITE_PATH="$TMP"
export DRY_RUN=false

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/agents-md-guidance.sh"
UPDATED_ITEMS=()

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
  esac
done
if [ "$VERBOSE" = false ]; then
  log() { :; }
  warn() { echo "WARN: $1" >&2; }
fi

MU_FILE="$TMP/wp-content/mu-plugins/wp-coding-agents-agents-md.php"
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
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | cut -d' ' -f1
  else
    md5 -q "$1"
  fi
}

file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

assert_mode_0644() {
  local file="$1" name="$2" got
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

assert_fails() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL $name"
    echo "    command unexpectedly succeeded: $*"
    FAILED=$((FAILED + 1))
  else
    echo "  ok   $name"
  fi
}

echo "==> register Homeboy Codebox guidance"
(
  umask 077
  agents_md_guidance_sync_homeboy_codebox true
)

assert_php_lint "$MU_FILE" "guidance mu-plugin parses with php -l"
assert_mode_0644 "$MU_FILE" "mu-plugin mode 0644 after fresh write under umask 077"

if grep -q "BEGIN agents-md-guidance:homeboy-codebox-agent-tasks" "$MU_FILE"; then
  echo "  ok   Homeboy Codebox block present"
else
  echo "  FAIL Homeboy Codebox block missing"
  FAILED=$((FAILED + 1))
fi

echo "==> re-register Homeboy Codebox guidance (idempotent)"
HASH_BEFORE=$(file_hash "$MU_FILE")
agents_md_guidance_sync_homeboy_codebox true
HASH_AFTER=$(file_hash "$MU_FILE")
assert_eq "$HASH_AFTER" "$HASH_BEFORE" "file unchanged on re-register"

echo "==> invalid public API inputs fail before writing broken PHP"
assert_fails "invalid section id rejected" agents_md_guidance_register "bad section" 36 "Bad" "Bad" "## Bad"
assert_fails "invalid priority rejected" agents_md_guidance_register "bad-priority" "later" "Bad" "Bad" "## Bad"
assert_fails "invalid sync availability rejected" agents_md_guidance_sync_homeboy_codebox maybe

echo "==> apply datamachine_sections action and inspect SectionRegistry call"
SHIM="$TMP/section-shim.php"
cat > "$SHIM" <<PHP
<?php
namespace DataMachine\Engine\AI {
    class SectionRegistry {
        public static array \$calls = [];
        public static function register( string \$filename, string \$slug, int \$priority, callable \$callback, array \$args = [] ): void {
            self::\$calls[] = [ \$filename, \$slug, \$priority, \$callback, \$args ];
        }
    }
}

namespace {
    define( 'ABSPATH', '/' );
    \$GLOBALS['actions'] = [];
    function add_action( \$tag, \$callback, \$priority = 10 ) {
        \$GLOBALS['actions'][\$tag][] = \$callback;
    }
    require '$MU_FILE';
    foreach ( \$GLOBALS['actions']['datamachine_sections'] ?? [] as \$callback ) {
        \$callback();
    }
    \$call = \DataMachine\Engine\AI\SectionRegistry::\$calls[0] ?? null;
    \$content = \$call ? (string) call_user_func( \$call[3] ) : '';
    echo json_encode([
        'filename' => \$call[0] ?? null,
        'slug' => \$call[1] ?? null,
        'priority' => \$call[2] ?? null,
        'label' => \$call[4]['label'] ?? null,
        'starts_with_homeboy_style_category' => str_starts_with( \$content, '**Agent tasks:**' ),
        'has_agent_task_verbs' => str_contains( \$content, 'homeboy agent-task submit|run|run-plan|status|logs|artifacts|promote' ),
        'has_sandbox_mode' => str_contains( \$content, 'use sandbox mode for Codebox coding tasks' ),
        'has_old_workflow_comparison' => str_contains( \$content, 'instead of' ) || str_contains( \$content, 'manual chat-session fleets' ),
    ]);
}
PHP

RESULT=$(php "$SHIM")
EXPECTED='{"filename":"AGENTS.md","slug":"homeboy-codebox-agent-tasks","priority":36,"label":"Homeboy Codebox agent tasks","starts_with_homeboy_style_category":true,"has_agent_task_verbs":true,"has_sandbox_mode":true,"has_old_workflow_comparison":false}'
assert_eq "$RESULT" "$EXPECTED" "SectionRegistry receives Homeboy Codebox guidance section"

echo "==> unregister Homeboy Codebox guidance"
chmod 0600 "$MU_FILE"
agents_md_guidance_sync_homeboy_codebox false
assert_mode_0644 "$MU_FILE" "mu-plugin mode 0644 after unregister"
if grep -q "BEGIN agents-md-guidance:homeboy-codebox-agent-tasks" "$MU_FILE"; then
  echo "  FAIL Homeboy Codebox block still present after unregister"
  FAILED=$((FAILED + 1))
else
  echo "  ok   Homeboy Codebox block removed"
fi
assert_php_lint "$MU_FILE" "post-unregister file parses with php -l"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all AGENTS.md guidance assertions passed"
