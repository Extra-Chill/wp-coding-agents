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
source "$SCRIPT_DIR/lib/source-policy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/agents-md-guidance.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/guidance/_dispatch.sh"
SOURCE_MODE="${SOURCE_MODE:-workspace}"
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

assert_mode_0664() {
  local file="$1" name="$2" got
  got=$(file_mode "$file")
  if [ "$got" = "664" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: 664"
    FAILED=$((FAILED + 1))
  fi
}

assert_group() {
  local file="$1" name="$2" got want
  got=$(stat -c %G "$file" 2>/dev/null || stat -f %Sg "$file")
  want=$(stat -c %G "$(dirname "$file")" 2>/dev/null || stat -f %Sg "$(dirname "$file")")
  if [ "$got" = "$want" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    got:  $got"
    echo "    want: $want (parent dir's group)"
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

echo "==> register generic guidance"
(
  umask 077
  agents_md_guidance_register "sample-guidance" 36 "Sample guidance" "Sample generated guidance." "## Sample guidance"
)

assert_php_lint "$MU_FILE" "guidance mu-plugin parses with php -l"
assert_mode_0664 "$MU_FILE" "mu-plugin mode 0664 after fresh write under umask 077"
assert_group "$MU_FILE" "mu-plugin group after fresh write"

if grep -q "BEGIN agents-md-guidance:sample-guidance" "$MU_FILE"; then
  echo "  ok   sample guidance block present"
else
  echo "  FAIL sample guidance block missing"
  FAILED=$((FAILED + 1))
fi

echo "==> re-register generic guidance (idempotent)"
HASH_BEFORE=$(file_hash "$MU_FILE")
agents_md_guidance_register "sample-guidance" 36 "Sample guidance" "Sample generated guidance." "## Sample guidance"
HASH_AFTER=$(file_hash "$MU_FILE")
assert_eq "$HASH_AFTER" "$HASH_BEFORE" "file unchanged on re-register"

echo "==> invalid public API inputs fail before writing broken PHP"
assert_fails "invalid section id rejected" agents_md_guidance_register "bad section" 36 "Bad" "Bad" "## Bad"
assert_fails "invalid priority rejected" agents_md_guidance_register "bad-priority" "later" "Bad" "Bad" "## Bad"

echo "==> skip registration when Data Machine core gate is unavailable"
SHIM_DISABLED="$TMP/section-shim-disabled.php"
cat > "$SHIM_DISABLED" <<PHP
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
    echo json_encode([ 'calls' => count( \DataMachine\Engine\AI\SectionRegistry::\$calls ) ]);
}
PHP

RESULT=$(php "$SHIM_DISABLED")
EXPECTED='{"calls":0}'
assert_eq "$RESULT" "$EXPECTED" "SectionRegistry receives no wp-coding-agents guidance without core AGENTS gate"

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
    function datamachine_agents_md_enabled(): bool { return true; }
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
        'owner' => \$call[4]['owner'] ?? null,
        'freshness' => \$call[4]['freshness'] ?? null,
        'conditions' => \$call[4]['conditions'] ?? null,
        'content' => \$content,
    ]);
}
PHP

RESULT=$(php "$SHIM")
EXPECTED='{"filename":"AGENTS.md","slug":"sample-guidance","priority":36,"label":"Sample guidance","owner":"wp-coding-agents","freshness":"conditional","conditions":"Registered by wp-coding-agents when the integration is available; removed when unavailable.","content":"## Sample guidance"}'
assert_eq "$RESULT" "$EXPECTED" "SectionRegistry receives generic guidance section"

echo "==> unregister generic guidance"
chmod 0600 "$MU_FILE"
agents_md_guidance_unregister "sample-guidance"
assert_mode_0664 "$MU_FILE" "mu-plugin mode 0664 after unregister"
assert_group "$MU_FILE" "mu-plugin group after unregister"
if grep -q "BEGIN agents-md-guidance:sample-guidance" "$MU_FILE"; then
  echo "  FAIL sample guidance block still present after unregister"
  FAILED=$((FAILED + 1))
else
  echo "  ok   sample guidance block removed"
fi
assert_php_lint "$MU_FILE" "post-unregister file parses with php -l"

echo "==> sync WordPress coding-agent boundaries"
# Emulate an existing installation created before wp-coding-agents registered
# its sections at a deterministic late priority.
python3 - "$MU_FILE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text().replace("\n}, 100 );\n", "\n} );\n")
content += "\nadd_action( 'unrelated_action', static function () {}, 100 );\n"
path.write_text(content)
PY
guidance_sync_all
assert_php_lint "$MU_FILE" "WordPress boundary guidance parses with php -l"
if grep -q "BEGIN agents-md-guidance:wp-cli-transport" "$MU_FILE"; then
  echo "  ok   WordPress CLI transport filter present"
else
  echo "  FAIL WordPress CLI transport filter missing"
  FAILED=$((FAILED + 1))
fi
if grep -q '^}, 100 );$' "$MU_FILE"; then
  echo "  ok   existing action wrapper normalized to priority 100"
else
  echo "  FAIL existing action wrapper priority was not normalized"
  FAILED=$((FAILED + 1))
fi
if grep -q 'BEGIN agents-md-guidance:wordpress-source' "$MU_FILE" && grep -q 'BEGIN agents-md-guidance:abilities' "$MU_FILE"; then
  echo "  ok   WordPress boundary guidance blocks present"
else
  echo "  FAIL WordPress boundary guidance blocks missing"
  FAILED=$((FAILED + 1))
fi
if grep -q 'studio wp' "$MU_FILE"; then
  echo "  FAIL static WordPress guidance hardcodes studio wp"
  FAILED=$((FAILED + 1))
else
  echo "  ok   static WordPress guidance has no environment-specific WP-CLI prefix"
fi

HASH_BEFORE=$(file_hash "$MU_FILE")
guidance_sync_all
HASH_AFTER=$(file_hash "$MU_FILE")
assert_eq "$HASH_AFTER" "$HASH_BEFORE" "WordPress boundary sync is idempotent"

echo "==> generated Studio commands use the selected transport non-interactively"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/studio" <<'SH'
#!/bin/bash
[ "$1" = wp ] || exit 1
shift
case " $* " in *" datamachine memory compose AGENTS.md "*) exit 0 ;; esac
exit 1
SH
chmod +x "$TMP/bin/studio"
wp_cli_transport_set studio wp
guidance_sync_all
if grep -q "return 'studio wp'" "$MU_FILE"; then
  echo "  ok   Studio transport stored in generated guidance"
else
  echo "  FAIL Studio transport was not stored in generated guidance"
  FAILED=$((FAILED + 1))
fi
TRANSPORT_SHIM="$TMP/transport-shim.php"
cat > "$TRANSPORT_SHIM" <<PHP
<?php
define( 'ABSPATH', '/' );
\$GLOBALS['actions'] = [];
\$GLOBALS['filters'] = [];
class TransportSectionRegistry { public static function register( \$file, \$section, \$priority, \$callback, \$metadata = [] ): void {} }
class_alias( 'TransportSectionRegistry', 'DataMachine\\Engine\\AI\\SectionRegistry' );
function add_action( \$tag, \$callback, \$priority = 10 ) { \$GLOBALS['actions'][\$tag][\$priority][] = \$callback; }
function add_filter( \$tag, \$callback, \$priority = 10 ) { \$GLOBALS['filters'][\$tag][\$priority][] = \$callback; }
function apply_filters( \$tag, \$value ) {
    if ( empty( \$GLOBALS['filters'][\$tag] ) ) { return \$value; }
    ksort( \$GLOBALS['filters'][\$tag] );
    foreach ( \$GLOBALS['filters'][\$tag] as \$callbacks ) { foreach ( \$callbacks as \$callback ) { \$value = \$callback( \$value ); } }
    return \$value;
}
function datamachine_agents_md_enabled(): bool { return true; }
require '$MU_FILE';
ksort( \$GLOBALS['actions']['datamachine_sections'] );
foreach ( \$GLOBALS['actions']['datamachine_sections'] as \$callbacks ) { foreach ( \$callbacks as \$callback ) { \$callback(); } }
echo apply_filters( 'datamachine_wp_cli_cmd', 'wp --path=/path/to/site' );
PHP
GENERATED_PREFIX=$(php "$TRANSPORT_SHIM")
assert_eq "$GENERATED_PREFIX" "studio wp --path=/path/to/site" "Studio AGENTS command prefix preserves path"
if env -i PATH="$TMP/bin:/usr/bin:/bin" bash -c "$GENERATED_PREFIX datamachine memory compose AGENTS.md"; then
  echo "  ok   generated Studio command executes without bare wp"
else
  echo "  FAIL generated Studio command does not execute without bare wp"
  FAILED=$((FAILED + 1))
fi
wp_cli_transport_set wp
guidance_sync_all
GENERATED_PREFIX=$(php "$TRANSPORT_SHIM")
assert_eq "$GENERATED_PREFIX" "wp --path=/path/to/site" "generic AGENTS command prefix retains wp"

echo "==> WordPress guidance wins mixed-version registration"
MIXED_SHIM="$TMP/mixed-section-shim.php"
cat > "$MIXED_SHIM" <<PHP
<?php
namespace DataMachine\Engine\AI {
    class SectionRegistry {
        public static array \$sections = [];
        public static function register( string \$filename, string \$slug, int \$priority, callable \$callback, array \$args = [] ): void {
            self::\$sections[\$slug] = [ \$filename, \$slug, \$priority, \$callback, \$args ];
        }
    }
}

namespace {
    define( 'ABSPATH', '/' );
    function datamachine_agents_md_enabled(): bool { return true; }
    \$GLOBALS['actions'] = [];
    function add_action( \$tag, \$callback, \$priority = 10 ) {
    \$GLOBALS['actions'][\$tag][\$priority][] = \$callback;
}
function add_filter( \$tag, \$callback, \$priority = 10 ) {
    \$GLOBALS['filters'][\$tag][\$priority][] = \$callback;
}
    add_action( 'datamachine_sections', static function () {
        \DataMachine\Engine\AI\SectionRegistry::register( 'AGENTS.md', 'wordpress-source', 30, static fn() => 'old source', [ 'owner' => 'data-machine-code' ] );
        \DataMachine\Engine\AI\SectionRegistry::register( 'AGENTS.md', 'abilities', 20, static fn() => 'old abilities', [ 'owner' => 'data-machine-code' ] );
    } );
    require '$MU_FILE';
    ksort( \$GLOBALS['actions']['datamachine_sections'] );
    foreach ( \$GLOBALS['actions']['datamachine_sections'] as \$callbacks ) {
        foreach ( \$callbacks as \$callback ) { \$callback(); }
    }
    \$source = \DataMachine\Engine\AI\SectionRegistry::\$sections['wordpress-source'];
    \$abilities = \DataMachine\Engine\AI\SectionRegistry::\$sections['abilities'];
    \$source_content = (string) call_user_func( \$source[3] );
    \$abilities_content = (string) call_user_func( \$abilities[3] );
    echo json_encode([
        'source_priority' => \$source[2],
        'abilities_priority' => \$abilities[2],
        'source_owner' => \$source[4]['owner'] ?? null,
        'abilities_owner' => \$abilities[4]['owner'] ?? null,
        'source_static' => ( \$source[4]['freshness'] ?? null ) === 'static',
        'abilities_static' => ( \$abilities[4]['freshness'] ?? null ) === 'static',
        'source_has_core' => str_contains( \$source_content, '\`wp-includes/\`' ),
        'source_has_code' => str_contains( \$source_content, '\`wp-content/plugins/\`' ) && str_contains( \$source_content, '\`wp-content/themes/\`' ),
        'source_promotes_direct_reference' => str_contains( \$source_content, 'verify core APIs, hooks, conventions, and runtime behavior instead of relying on assumptions' ),
        'source_keeps_installed_tree_read_only' => str_contains( \$source_content, 'Make code changes in the configured repository checkout' ),
        'abilities_has_tools' => str_contains( \$abilities_content, 'active runtime tool listings' ),
    ]);
}
PHP

RESULT=$(php "$MIXED_SHIM")
EXPECTED='{"source_priority":1,"abilities_priority":2,"source_owner":"wp-coding-agents","abilities_owner":"wp-coding-agents","source_static":true,"abilities_static":true,"source_has_core":true,"source_has_code":true,"source_promotes_direct_reference":true,"source_keeps_installed_tree_read_only":true,"abilities_has_tools":true}'
assert_eq "$RESULT" "$EXPECTED" "wp-coding-agents owns ordered guidance after mixed-version registration"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all AGENTS.md guidance assertions passed"
