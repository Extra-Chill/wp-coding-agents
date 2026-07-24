#!/bin/bash
# tests/homeboy-agents-md.sh — Homeboy AGENTS.md routing guidance regression.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PHP_BIN=$(command -v php)

mkdir -p "$TMP/wp-content/mu-plugins" "$TMP/bin"
export SITE_PATH="$TMP"
export DRY_RUN=false

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/agents-md-guidance.sh"
UPDATED_ITEMS=()

log() { :; }
warn() { echo "WARN: $1" >&2; }

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

cat > "$TMP/bin/homeboy" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$TMP/bin/homeboy"

echo "==> homeboy present: register concise routing guidance"
PATH="$TMP/bin:$PATH" agents_md_guidance_sync_homeboy_cli

if ! php -l "$MU_FILE" >/dev/null 2>&1; then
  echo "  FAIL generated guidance does not parse"
  FAILED=$((FAILED + 1))
fi

SHIM="$TMP/section-shim.php"
cat > "$SHIM" <<PHP
<?php
namespace DataMachine\Engine\AI {
    class SectionRegistry {
        public static array \$calls = [];
        public static function register( string \$filename, string \$slug, int \$priority, callable \$callback, array \$args = [] ): void {
            self::\$calls[ \$slug ] = [ \$filename, \$slug, \$priority, \$callback, \$args ];
        }
    }
}
namespace {
    define( 'ABSPATH', '/' );
    function datamachine_agents_md_enabled(): bool { return true; }
    \$GLOBALS['actions'] = [];
    function add_action( \$tag, \$callback, \$priority = 10 ) { \$GLOBALS['actions'][\$tag][] = \$callback; }
    require '$MU_FILE';
    foreach ( \$GLOBALS['actions']['datamachine_sections'] ?? [] as \$callback ) { \$callback(); }
    \$call = \DataMachine\Engine\AI\SectionRegistry::\$calls['homeboy-cli'] ?? null;
    \$content = \$call ? (string) call_user_func( \$call[3] ) : '';
    if ( '1' === getenv( 'CONTENT_ONLY' ) ) { echo \$content; exit; }
    echo json_encode([
        'filename' => \$call[0] ?? null,
        'slug' => \$call[1] ?? null,
        'priority' => \$call[2] ?? null,
        'label' => \$call[4]['label'] ?? null,
        'owner' => \$call[4]['owner'] ?? null,
        'freshness' => \$call[4]['freshness'] ?? null,
        'has_heading' => str_starts_with( \$content, '## Homeboy' ),
        'has_boundary' => str_contains( \$content, 'Data Machine Code owns authoritative repository and worktree state' ),
        'has_cook' => str_contains( \$content, 'homeboy agent-task cook' ),
        'has_fanout' => str_contains( \$content, 'homeboy agent-task fanout cook-batch' ),
        'has_review' => str_contains( \$content, 'homeboy review' ),
        'has_runs' => str_contains( \$content, 'homeboy runs' ),
        'has_stateful' => str_contains( \$content, 'homeboy agent-task loop' ) && str_contains( \$content, 'homeboy agent-task controller' ),
        'has_health' => str_contains( \$content, 'homeboy status' ) && str_contains( \$content, 'homeboy runner status' ),
        'has_operator_boundary' => str_contains( \$content, 'only when the user explicitly asks' ),
        'has_discovery' => str_contains( \$content, 'homeboy --help' ) && str_contains( \$content, 'homeboy <command> --help' ),
        'no_exhaustive_map' => ! str_contains( \$content, 'Common entrypoints:' ) && ! str_contains( \$content, 'Deploy components to remote server' ),
    ]);
}
PHP

RESULT=$(PATH="$TMP/bin:$PATH" php "$SHIM")
EXPECTED='{"filename":"AGENTS.md","slug":"homeboy-cli","priority":30,"label":"Homeboy","owner":"wp-coding-agents","freshness":"live","has_heading":true,"has_boundary":true,"has_cook":true,"has_fanout":true,"has_review":true,"has_runs":true,"has_stateful":true,"has_health":true,"has_operator_boundary":true,"has_discovery":true,"no_exhaustive_map":true}'
assert_eq "$RESULT" "$EXPECTED" "SectionRegistry receives concise Homeboy routing guidance"

echo "==> re-sync with homeboy present (idempotent)"
HASH_BEFORE=$(md5sum "$MU_FILE" | cut -d' ' -f1)
PATH="$TMP/bin:$PATH" agents_md_guidance_sync_homeboy_cli
HASH_AFTER=$(md5sum "$MU_FILE" | cut -d' ' -f1)
assert_eq "$HASH_AFTER" "$HASH_BEFORE" "file unchanged on re-sync"

echo "==> live callback omits guidance when homeboy disappears"
EMPTY_BIN="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN"
ABSENT_RESULT=$(CONTENT_ONLY=1 PATH="$EMPTY_BIN" "$PHP_BIN" "$SHIM")
if [ -n "$ABSENT_RESULT" ]; then
  echo "  FAIL callback rendered guidance without homeboy: $ABSENT_RESULT"
  FAILED=$((FAILED + 1))
else
  echo "  ok   callback omits guidance without homeboy"
fi

echo "==> sync removes section when homeboy is absent"
SANDBIN="$TMP/sandbin"
mkdir -p "$SANDBIN"
for tool in grep mktemp mv cmp chmod python3 md5sum cat sed awk rm cut stat dirname; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$SANDBIN/$tool"
done
PATH="$SANDBIN" agents_md_guidance_sync_homeboy_cli

if grep -q "BEGIN agents-md-guidance:homeboy-cli" "$MU_FILE"; then
  echo "  FAIL homeboy-cli block remained after absence sync"
  FAILED=$((FAILED + 1))
else
  echo "  ok   homeboy-cli block removed"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all Homeboy AGENTS.md routing assertions passed"
