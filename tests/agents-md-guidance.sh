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

# Isolate the #633 managed-binary resolution from whatever the test host
# actually has installed. Without this override, a dev box with a real
# /usr/local/bin/homeboy (this repo's own dev/CI hosts do) would let the
# guidance resolver's candidate #2 win over every PATH-based fixture below,
# silently invalidating the #575 assertions that depend on the fixture path
# being the one baked into the mu-plugin.
export WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMP/no-managed-homeboy-in-tests"
unset WP_CODING_AGENTS_HOMEBOY_BIN WP_CODING_AGENTS_COMPOSE_USER WP_CODING_AGENTS_COMPOSE_GROUP 2>/dev/null || true

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/agents-md-guidance.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/guidance/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"
SOURCE_MODE="${SOURCE_MODE:-workspace}"
UPDATED_ITEMS=()

PRODUCER_VERSION="$(agents_md_guidance_producer_version)"
PRODUCER_SOURCE="$(agents_md_guidance_producer_source)"

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
AGENT_WP="$TMP/wp-content/mu-plugins/wp-coding-agents-agent-wp"
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

assert_contains() {
  local file="$1" text="$2" name="$3"
  if grep -Fq -- "$text" "$file"; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "    missing: $text"
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
  got=$(file_group "$file")
  want=$(file_group "$(dirname "$file")")
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

echo "==> provenance identities distinguish dirty and packaged producers"
DIRTY="$TMP/dirty"
mkdir -p "$DIRTY/lib" "$DIRTY/guidance"
cp "$SCRIPT_DIR/VERSION" "$DIRTY/VERSION"
cp "$SCRIPT_DIR/lib/agents-md-guidance.sh" "$DIRTY/lib/agents-md-guidance.sh"
cp "$SCRIPT_DIR"/guidance/*.sh "$DIRTY/guidance/"
git -C "$DIRTY" init -q
git -C "$DIRTY" add .
git -C "$DIRTY" -c user.email=tests@example.invalid -c user.name=tests commit -qm fixture
printf '%s\n' '# dirty fixture' >> "$DIRTY/guidance/homeboy.sh"
DIRTY_SOURCE=$(SCRIPT_DIR="$DIRTY"; source "$DIRTY/lib/agents-md-guidance.sh"; agents_md_guidance_producer_source)
case "$DIRTY_SOURCE" in
  dirty-sha256:*|dirty-version:*) echo "  ok   dirty checkout never claims a clean commit identity" ;;
  *) echo "  FAIL dirty checkout claimed unexpected producer identity: $PRODUCER_SOURCE"; FAILED=$((FAILED + 1)) ;;
esac

PACKAGE="$TMP/package"
mkdir -p "$PACKAGE/lib"
cp "$SCRIPT_DIR/VERSION" "$PACKAGE/VERSION"
cp "$SCRIPT_DIR/lib/agents-md-guidance.sh" "$PACKAGE/lib/agents-md-guidance.sh"
mkdir -p "$PACKAGE/guidance"
cp "$SCRIPT_DIR"/guidance/*.sh "$PACKAGE/guidance/"
PACKAGE_SOURCE=$(SCRIPT_DIR="$PACKAGE"; source "$PACKAGE/lib/agents-md-guidance.sh"; agents_md_guidance_producer_source)
case "$PACKAGE_SOURCE" in
  package-sha256:*) echo "  ok   packaged producer uses portable content identity" ;;
  *) echo "  FAIL packaged producer identity: $PACKAGE_SOURCE"; FAILED=$((FAILED + 1)) ;;
esac
PACKAGE_FALLBACK=$(PATH="/nonexistent"; SCRIPT_DIR="$PACKAGE"; source "$PACKAGE/lib/agents-md-guidance.sh"; agents_md_guidance_producer_source)
assert_eq "$PACKAGE_FALLBACK" "package-version:$PRODUCER_VERSION" "packaged producer has an explicit no-hash fallback"

echo "==> old producer recomposes to current guidance"
OLD_PRODUCER='version=1.21.1 source=commit:0000000000000000000000000000000000000000'
printf '%s\n' "<!-- wp-coding-agents-provenance: $OLD_PRODUCER -->" > "$TMP/AGENTS.md"
if agents_md_guidance_verify_composed_provenance "$TMP/AGENTS.md"; then
  echo "  FAIL old composed producer was accepted as current"
  FAILED=$((FAILED + 1))
else
  echo "  ok   old composed producer requires recompose"
fi
printf '%s\n' "$(agents_md_guidance_provenance_markdown)" 'request explicit operator authorization before invoking a coding runtime directly' > "$TMP/AGENTS.md"
if agents_md_guidance_verify_composed_provenance "$TMP/AGENTS.md"; then
  echo "  ok   recompose produces current provenance and recovery behavior"
else
  echo "  FAIL recomposed guidance was not current"
  FAILED=$((FAILED + 1))
fi
printf '%s\n' '## Guidance intentionally disabled' > "$TMP/AGENTS.md"
if agents_md_guidance_verify_composed_provenance "$TMP/AGENTS.md"; then
  echo "  FAIL disabled guidance was incorrectly active"
  FAILED=$((FAILED + 1))
else
  STATUS=$?
  assert_eq "$STATUS" "1" "missing provenance requires an authoritative gate check"
fi
printf '%s\n' '## User guidance before failed compose' > "$TMP/precompose"
cp "$TMP/precompose" "$TMP/precompose.backup"
printf '%s\n' 'partial stale compose output' > "$TMP/precompose"
agents_md_guidance_restore_precompose_state "$TMP/precompose" "$TMP/precompose.backup" true
assert_eq "$(<"$TMP/precompose")" '## User guidance before failed compose' "failed or stale compose restores existing user guidance"
printf '%s\n' 'partial output without predecessor' > "$TMP/new-precompose"
agents_md_guidance_restore_precompose_state "$TMP/new-precompose" "$TMP/missing-backup" false
if [ -e "$TMP/new-precompose" ]; then
  echo "  FAIL failed compose left a new partial AGENTS.md"
  FAILED=$((FAILED + 1))
else
  echo "  ok   failed compose removes a new partial AGENTS.md"
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
        'producer_version' => \$call[4]['producer_version'] ?? null,
        'producer_source' => \$call[4]['producer_source'] ?? null,
        'freshness' => \$call[4]['freshness'] ?? null,
        'conditions' => \$call[4]['conditions'] ?? null,
        'content' => \$content,
    ]);
}
PHP

RESULT=$(php "$SHIM")
EXPECTED="{\"filename\":\"AGENTS.md\",\"slug\":\"sample-guidance\",\"priority\":36,\"label\":\"Sample guidance\",\"owner\":\"wp-coding-agents\",\"producer_version\":\"$PRODUCER_VERSION\",\"producer_source\":\"$PRODUCER_SOURCE\",\"freshness\":\"conditional\",\"conditions\":\"Registered by wp-coding-agents when the integration is available; removed when unavailable.\",\"content\":\"<!-- wp-coding-agents-provenance: version=$PRODUCER_VERSION source=$PRODUCER_SOURCE -->\\n## Sample guidance\"}"
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
wp_cli_transport_set wp
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
if grep -q "return '$AGENT_WP'" "$MU_FILE"; then
  echo "  ok   agent WP-CLI transport stored in generated guidance"
else
  echo "  FAIL agent WP-CLI transport was not stored in generated guidance"
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
assert_eq "$GENERATED_PREFIX" "$AGENT_WP --path=/path/to/site" "agent WP-CLI command prefix preserves path"
if env -i PATH="$TMP/bin:/usr/bin:/bin" bash -c "$GENERATED_PREFIX datamachine memory compose AGENTS.md"; then
  echo "  ok   generated agent command executes through selected transport"
else
  echo "  FAIL generated agent command does not execute through selected transport"
  FAILED=$((FAILED + 1))
fi
wp_cli_transport_set wp
guidance_sync_all
GENERATED_PREFIX=$(php "$TRANSPORT_SHIM")
assert_eq "$GENERATED_PREFIX" "$AGENT_WP --path=/path/to/site" "generic AGENTS command uses the agent transport"

echo "==> agent WP-CLI wrapper runs as the current speaker when --user is omitted (#899)"
SPEAKER_SITE="$TMP/speaker-site"
SPEAKER_WP="$SPEAKER_SITE/wp-content/mu-plugins/wp-coding-agents-agent-wp"
mkdir -p "$TMP/speaker-bin"
# Stub transport: echo argv one per line, and emit WP-CLI's ambiguous-user
# warning for whatever --user value it received, plus an unrelated warning.
cat > "$TMP/speaker-bin/stub-wp" <<'SH'
#!/bin/bash
for argument in "$@"; do
  printf 'arg:%s\n' "$argument"
  case "$argument" in
    --user=*) printf "Warning: Ambiguous user match detected (both ID and user_login exist for identifier '%s'). WP-CLI will default to the ID, but you can force user_login instead with WP_CLI_FORCE_USER_LOGIN=1.\n" "${argument#--user=}" >&2 ;;
  esac
done
printf '%s\n' 'Warning: an unrelated diagnostic.' >&2
exit 7
SH
chmod +x "$TMP/speaker-bin/stub-wp"
(
  SITE_PATH="$SPEAKER_SITE/"
  _agents_md_guidance_write_agent_wp_cli_transport "$SPEAKER_WP" "$TMP/speaker-bin/stub-wp" --allow-root
)
SPEAKER_SITE_PATH="$SPEAKER_SITE"

# run_speaker <ROADIE_PERSON_ID or __unset__> <args...>; sets SPEAKER_OUT/ERR/STATUS.
run_speaker() {
  local person="$1"
  shift
  SPEAKER_STATUS=0
  if [ "$person" = __unset__ ]; then
    env -u ROADIE_PERSON_ID "$SPEAKER_WP" "$@" >"$TMP/speaker.out" 2>"$TMP/speaker.err" || SPEAKER_STATUS=$?
  else
    ROADIE_PERSON_ID="$person" "$SPEAKER_WP" "$@" >"$TMP/speaker.out" 2>"$TMP/speaker.err" || SPEAKER_STATUS=$?
  fi
  SPEAKER_OUT="$(tr '\n' ' ' <"$TMP/speaker.out")"
  SPEAKER_ERR="$(cat "$TMP/speaker.err")"
}

assert_no_ambiguous_warning() {
  case "$SPEAKER_ERR" in
    *"Ambiguous user match"*) echo "  FAIL $1"; echo "    stderr: $SPEAKER_ERR"; FAILED=$((FAILED + 1)) ;;
    *) echo "  ok   $1" ;;
  esac
}

assert_ambiguous_warning() {
  case "$SPEAKER_ERR" in
    *"identifier '$2'"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1"; echo "    stderr: $SPEAKER_ERR"; FAILED=$((FAILED + 1)) ;;
  esac
}

run_speaker "wordpress:$SPEAKER_SITE_PATH:1" --path="$SPEAKER_SITE_PATH" intelligence wiki search 'two words'
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:--user=1 arg:--path=$SPEAKER_SITE_PATH arg:intelligence arg:wiki arg:search arg:two words " "matching speaker injects --user=<id> and preserves quoted args"
assert_eq "$SPEAKER_STATUS" "7" "wrapper preserves the transport exit status"
assert_no_ambiguous_warning "ambiguous-user warning suppressed for the injected id"
assert_eq "$SPEAKER_ERR" "Warning: an unrelated diagnostic." "unrelated warnings still reach stderr"

run_speaker "wordpress:$SPEAKER_SITE_PATH/:42" eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:--user=42 arg:eval arg:1 " "speaker site path matches after trimming trailing slashes"

run_speaker "wordpress:$SPEAKER_SITE_PATH:1" --user=chubes eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:--user=chubes arg:eval arg:1 " "explicit --user=<value> is never overridden"

run_speaker "wordpress:$SPEAKER_SITE_PATH:1" --user 5 eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:--user arg:5 arg:eval arg:1 " "explicit --user <value> is never overridden"

run_speaker "wordpress:$SPEAKER_SITE_PATH:2" --user=1 eval 1
assert_ambiguous_warning "caller-supplied --user still shows the ambiguous-user warning" 1

run_speaker "wordpress:$TMP/other-site:1" eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:eval arg:1 " "speaker for a different site leaves args untouched"

run_speaker "wordpress:$SPEAKER_SITE_PATH/sub:1" eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:eval arg:1 " "speaker for a nested path leaves args untouched"

run_speaker __unset__ eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:eval arg:1 " "no ROADIE_PERSON_ID leaves args untouched"

run_speaker "" eval 1
assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:eval arg:1 " "empty ROADIE_PERSON_ID leaves args untouched"

for malformed in \
  "wordpress:$SPEAKER_SITE_PATH:0" \
  "wordpress:$SPEAKER_SITE_PATH:-1" \
  "wordpress:$SPEAKER_SITE_PATH:01" \
  "wordpress:$SPEAKER_SITE_PATH:admin" \
  "wordpress:$SPEAKER_SITE_PATH:1 --user=2" \
  "wordpress:$SPEAKER_SITE_PATH:" \
  "wordpress:$SPEAKER_SITE_PATH" \
  "wordpress:1" \
  "discord:$SPEAKER_SITE_PATH:1" \
  "$SPEAKER_SITE_PATH:1"; do
  run_speaker "$malformed" eval 1
  assert_eq "$SPEAKER_OUT" "arg:--allow-root arg:eval arg:1 " "malformed ROADIE_PERSON_ID '$malformed' leaves args untouched"
done

# A legacy --user=1 caller with no injection still sees the warning.
run_speaker __unset__ --user=1 eval 1
assert_ambiguous_warning "warning shown when the wrapper injected nothing" 1

# Only the injected id's warning is dropped, not another identifier's.
cat > "$TMP/speaker-bin/stub-wp" <<'SH'
#!/bin/bash
printf "Warning: Ambiguous user match detected (both ID and user_login exist for identifier '7').\n" >&2
exit 0
SH
run_speaker "wordpress:$SPEAKER_SITE_PATH:1" eval 1
assert_ambiguous_warning "ambiguous warning for a different identifier is kept" 7

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

echo "==> generate and remove Homeboy control-plane recovery guidance"
mkdir -p "$TMP/homeboy-bin"
cat > "$TMP/homeboy-bin/homeboy" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP/homeboy-bin/homeboy"
PATH="$TMP/homeboy-bin:$PATH"
export PATH
guidance_sync_unit homeboy
assert_contains "$MU_FILE" 'Homeboy remains the normal owner of tracked coding work.' "Homeboy guidance preserves normal ownership"
assert_contains "$MU_FILE" "wp-coding-agents-provenance: version=$PRODUCER_VERSION source=$PRODUCER_SOURCE" "Homeboy guidance records its producer provenance"
assert_contains "$MU_FILE" "'producer_version' => '$PRODUCER_VERSION'" "Homeboy metadata records its producer version"
assert_contains "$MU_FILE" 'homeboy agent-task cook --preview' "Homeboy guidance validates the selected route"
assert_contains "$MU_FILE" 'homeboy agent-task cook --help-full' "Homeboy guidance discovers exact alternative routes"
assert_contains "$MU_FILE" 'configured attempt and provider-rotation budget' "Homeboy guidance bounds recovery"
assert_contains "$MU_FILE" 'request explicit operator authorization before invoking a coding runtime directly' "Homeboy guidance requires direct-fallback authorization"
assert_contains "$MU_FILE" 'isolated Git worktree linked to the tracker' "Homeboy guidance requires an isolated linked worktree"
assert_contains "$MU_FILE" 'deterministic verification' "Homeboy guidance requires deterministic verification"
assert_contains "$MU_FILE" 'AI-disclosure policy' "Homeboy guidance preserves AI disclosure"
assert_contains "$MU_FILE" 'finalization occurred outside Homeboy' "Homeboy guidance records fallback finalization"
HOMEBOY_HASH_BEFORE=$(file_hash "$MU_FILE")
guidance_sync_unit homeboy
HOMEBOY_HASH_AFTER=$(file_hash "$MU_FILE")
assert_eq "$HOMEBOY_HASH_AFTER" "$HOMEBOY_HASH_BEFORE" "Homeboy guidance generation is idempotent"
echo "==> Homeboy guidance survives a compose with a minimal PATH (#575)"
# The composing process is not always an interactive shell. PHP-FPM, cron, a
# plugin upgrade, or a WP-CLI call with a trimmed environment all recompose
# AGENTS.md without an interactive PATH. Resolving the binary from
# getenv('PATH') at compose time therefore deleted the section on hosts where
# Homeboy was installed and executable.
assert_contains "$MU_FILE" "$TMP/homeboy-bin/homeboy" "Homeboy guidance bakes the absolute binary path"
if grep -Fq "getenv( 'PATH' )" "$MU_FILE"; then
  echo "  FAIL Homeboy guidance still resolves the binary from the ambient PATH"
  FAILED=$((FAILED + 1))
else
  echo "  ok   Homeboy guidance does not read the ambient PATH"
fi

# Execute the generated block with a deliberately empty PATH. This is the
# exact condition that silently dropped the section before the fix.
MINIMAL_PATH_SHIM="$TMP/minimal-path-shim.php"
cat > "$MINIMAL_PATH_SHIM" <<PHP
<?php
define( 'ABSPATH', '/' );
\$GLOBALS['actions'] = [];
\$GLOBALS['filters'] = [];
\$GLOBALS['sections'] = [];
class MinimalPathSectionRegistry {
    public static function register( \$file, \$section, \$priority, \$callback, \$metadata = [] ): void {
        \$GLOBALS['sections'][ \$section ] = \$callback;
    }
}
class_alias( 'MinimalPathSectionRegistry', 'DataMachine\\\\Engine\\\\AI\\\\SectionRegistry' );
function add_action( \$tag, \$callback, \$priority = 10 ) { \$GLOBALS['actions'][\$tag][\$priority][] = \$callback; }
function add_filter( \$tag, \$callback, \$priority = 10 ) { \$GLOBALS['filters'][\$tag][\$priority][] = \$callback; }
function apply_filters( \$tag, \$value ) { return \$value; }
function datamachine_agents_md_enabled(): bool { return true; }
// The composing process has no usable PATH — the #575 condition.
putenv( 'PATH=' );
require '$MU_FILE';
ksort( \$GLOBALS['actions']['datamachine_sections'] );
foreach ( \$GLOBALS['actions']['datamachine_sections'] as \$callbacks ) { foreach ( \$callbacks as \$callback ) { \$callback(); } }
\$rendered = isset( \$GLOBALS['sections']['homeboy-cli'] ) ? (string) \$GLOBALS['sections']['homeboy-cli']() : '';
echo json_encode([
    'registered' => isset( \$GLOBALS['sections']['homeboy-cli'] ),
    'renders'    => str_contains( \$rendered, '## Homeboy' ),
]);
PHP
RESULT=$(php "$MINIMAL_PATH_SHIM")
assert_eq "$RESULT" '{"registered":true,"renders":true}' "Homeboy guidance still composes with an empty PATH"

echo "==> managed-binary resolution prefers a world-executable path over an unreachable per-user copy (#633)"
# The per-user home is a stand-in for ~/.local/bin/homeboy on the syncing
# user's PATH — #633's actual production shape: parent directory 0700, so
# the binary is on PATH but unreachable by any other identity.
mkdir -p "$TMP/per-user-home/bin"
cat > "$TMP/per-user-home/bin/homeboy" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP/per-user-home/bin/homeboy"
chmod 0700 "$TMP/per-user-home"

# The managed binary: world-executable, standing in for the real
# /usr/local/bin/homeboy a host's homeboy-upgrade helper installs and
# upgrades.
mkdir -p "$TMP/managed"
cat > "$TMP/managed/homeboy" <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 "$TMP/managed/homeboy"
chmod 0755 "$TMP/managed"
export WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMP/managed/homeboy"

PATH="$TMP/per-user-home/bin:$TMP/homeboy-bin:/usr/bin:/bin"
export PATH
guidance_sync_unit homeboy
assert_contains "$MU_FILE" "$TMP/managed/homeboy" "Managed binary path is baked when a PATH candidate is unreachable"
if grep -qF "$TMP/per-user-home/bin/homeboy" "$MU_FILE"; then
  echo "  FAIL unreachable per-user binary path leaked into the mu-plugin"
  FAILED=$((FAILED + 1))
else
  echo "  ok   unreachable per-user binary path is never baked"
fi

export WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMP/no-managed-homeboy-in-tests"

echo "==> resolution recognizes a well-known system install that is off the syncing PATH (#636)"
# #636's production shape: the binary lives at /usr/local/bin/homeboy (a
# stand-in fixture path here), but the syncing shell's PATH does not contain
# that directory (upgrade/cron contexts), while the previously baked staler
# per-user copy is still the first candidate. The walk must still find the
# well-known install instead of leaving the section silently dropped.
mkdir -p "$TMP/well-known/bin"
cat > "$TMP/well-known/bin/homeboy" <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 "$TMP/well-known/bin/homeboy"
export WP_CODING_AGENTS_HOMEBOY_WELL_KNOWN_BINS="$TMP/well-known/bin/homeboy"
PATH="$TMP/per-user-home/bin:/usr/bin:/bin"
export PATH
guidance_sync_unit homeboy
assert_contains "$MU_FILE" "$TMP/well-known/bin/homeboy" "Well-known system install is baked even when off the syncing PATH"
if grep -qF "$TMP/per-user-home/bin/homeboy" "$MU_FILE"; then
  echo "  FAIL stale per-user binary path leaked into the mu-plugin"
  FAILED=$((FAILED + 1))
else
  echo "  ok   unreachable per-user candidate is skipped in favor of the well-known install"
fi
unset WP_CODING_AGENTS_HOMEBOY_WELL_KNOWN_BINS
rm -rf "$TMP/well-known"

echo "==> no reachable candidate anywhere warns instead of silently dropping the section (#633)"
# WP_CODING_AGENTS_COMPOSE_USER/GROUP simulate the web-server identity: names
# that cannot possibly match any real file's owner/group in this sandbox, so
# the reachability check falls through to a pure permission-bit walk exactly
# like it would for an unrelated www-data compose identity in production.
WARN_OUT="$TMP/warn-output.txt"
export WP_CODING_AGENTS_COMPOSE_USER="ec-simulated-web-user"
export WP_CODING_AGENTS_COMPOSE_GROUP="ec-simulated-web-group"
PATH="$TMP/per-user-home/bin:/usr/bin:/bin"
export PATH
guidance_sync_unit homeboy >/dev/null 2>"$WARN_OUT" || true
if grep -qF "$TMP/per-user-home/bin/homeboy" "$WARN_OUT"; then
  echo "  ok   unreachable candidate is named in the sync warning"
else
  echo "  FAIL sync warning did not name the unreachable candidate"
  echo "    warning output:"
  sed 's/^/      /' "$WARN_OUT"
  FAILED=$((FAILED + 1))
fi
if grep -q "compose identity" "$WARN_OUT"; then
  echo "  ok   sync warning explains the compose-identity mismatch"
else
  echo "  FAIL sync warning did not explain the compose-identity mismatch"
  FAILED=$((FAILED + 1))
fi
if grep -q 'BEGIN agents-md-guidance:homeboy-cli' "$MU_FILE"; then
  echo "  FAIL homeboy-cli guidance remains registered with no reachable candidate"
  FAILED=$((FAILED + 1))
else
  echo "  ok   homeboy-cli guidance is unregistered with no reachable candidate (visible, not silent)"
fi
unset WP_CODING_AGENTS_COMPOSE_USER WP_CODING_AGENTS_COMPOSE_GROUP

rm "$TMP/homeboy-bin/homeboy"
PATH="$TMP/homeboy-bin:/usr/bin:/bin"
export PATH
guidance_sync_unit homeboy
if grep -q 'BEGIN agents-md-guidance:homeboy-cli' "$MU_FILE"; then
  echo "  FAIL Homeboy guidance remains after Homeboy becomes unavailable"
  FAILED=$((FAILED + 1))
else
  echo "  ok   Homeboy guidance is removed when Homeboy becomes unavailable"
fi

echo "==> retired homeboy-codebox-agent-tasks guidance is removed on sync (#609)"
# Simulate an install that synced before #246 retired this section: it is
# still registered in the mu-plugin, but nothing in the current codebase
# renders it, so the only correct outcome is that a sync removes it.
RETIRED_CONTENT='**Agent tasks:** legacy content.

**Codebox executor:** legacy content duplicating the WP Codebox section.

**Workspace shape:** legacy content.

**WP Codebox agent mode:** legacy content.

**Codex provider:** legacy content with AI_PROVIDER_OPENAI_CODEX_* secrets.

**Claude Code provider:** legacy content with AI_PROVIDER_CLAUDE_CODE_REFRESH_TOKEN.

**Operator verbs:** legacy content.

**Chat bridges:** legacy content.'
agents_md_guidance_register "homeboy-codebox-agent-tasks" 36 "Homeboy Codebox agent tasks" "Homeboy-owned async coding-agent fan-out through WP Codebox sandboxes." "$RETIRED_CONTENT"
if grep -q "BEGIN agents-md-guidance:homeboy-codebox-agent-tasks" "$MU_FILE"; then
  echo "  ok   retired guidance fixture registered"
else
  echo "  FAIL could not register retired guidance fixture"
  FAILED=$((FAILED + 1))
fi

mkdir -p "$TMP/homeboy-bin"
cat > "$TMP/homeboy-bin/homeboy" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP/homeboy-bin/homeboy"
PATH="$TMP/homeboy-bin:$PATH"
export PATH

sync_homeboy_agents_md_guidance

if grep -q "BEGIN agents-md-guidance:homeboy-codebox-agent-tasks" "$MU_FILE"; then
  echo "  FAIL retired homeboy-codebox-agent-tasks guidance was not removed by sync"
  FAILED=$((FAILED + 1))
else
  echo "  ok   retired homeboy-codebox-agent-tasks guidance removed by sync"
fi
if grep -q "BEGIN agents-md-guidance:homeboy-cli" "$MU_FILE"; then
  echo "  ok   current homeboy-cli guidance is untouched by the retired-section cleanup"
else
  echo "  FAIL current homeboy-cli guidance was removed alongside the retired section"
  FAILED=$((FAILED + 1))
fi
assert_php_lint "$MU_FILE" "mu-plugin parses with php -l after retired-section cleanup"

RETIRED_HASH_BEFORE=$(file_hash "$MU_FILE")
sync_homeboy_agents_md_guidance
homeboy_retired_codebox_agents_md_guidance_remove
RETIRED_HASH_AFTER=$(file_hash "$MU_FILE")
assert_eq "$RETIRED_HASH_AFTER" "$RETIRED_HASH_BEFORE" "retired-section cleanup is idempotent on an install that never had the section"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all AGENTS.md guidance assertions passed"
