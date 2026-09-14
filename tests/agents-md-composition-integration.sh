#!/bin/bash
# Compose and execute Data Machine and Intelligence guidance with the host transport.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SITE_PATH="$TMP/site"
export DRY_RUN=false
mkdir -p "$SITE_PATH/wp-content/mu-plugins" "$TMP/bin"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/agents-md-guidance.sh"
log() { :; }

MU_FILE="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agents-md.php"
AGENT_WP="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agent-wp"

cat > "$TMP/bin/studio" <<'SH'
#!/bin/bash
[ "$1" = wp ] || exit 10
shift
exec "$(dirname "$0")/wp-host" "$@"
SH

cat > "$TMP/bin/wp" <<'SH'
#!/bin/bash
exec "$(dirname "$0")/wp-host" "$@"
SH

cat > "$TMP/bin/wp-host" <<'SH'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path=*|--allow-root) shift ;;
    *) break ;;
  esac
done
case "${1:-} ${2:-} ${3:-} ${4:-}" in
  "datamachine memory paths fixture") exit 0 ;;
  "intelligence search fixture ")
    printf '%s\n' 'Warning: The --context argument is already registered by another command.' >&2
    printf '%s\n' 'Warning: The --user argument is already registered by another command.' >&2
    printf '%s\n' 'Warning: The --path argument is already registered by another command.' >&2
    printf '%s\n' 'Warning: The --quiet argument is already registered by another command.' >&2
    printf '%s\n' 'Warning: an unrelated command diagnostic.' >&2
    printf '%s\n' 'search result'
    exit 0
    ;;
esac
exit 11
SH
chmod +x "$TMP/bin/studio" "$TMP/bin/wp" "$TMP/bin/wp-host"

cat > "$TMP/compose.php" <<'PHP'
<?php
define( 'ABSPATH', '/path/to/site/' );
$GLOBALS['actions'] = array();
$GLOBALS['filters'] = array();

function add_action( $tag, $callback, $priority = 10 ) { $GLOBALS['actions'][ $tag ][ $priority ][] = $callback; }
function add_filter( $tag, $callback, $priority = 10 ) { $GLOBALS['filters'][ $tag ][ $priority ][] = $callback; }
function apply_filters( $tag, $value ) {
    ksort( $GLOBALS['filters'][ $tag ] );
    foreach ( $GLOBALS['filters'][ $tag ] ?? array() as $callbacks ) {
        foreach ( $callbacks as $callback ) { $value = $callback( $value ); }
    }
    return $value;
}
function datamachine_agents_md_enabled(): bool { return true; }

class IntegrationSectionRegistry {
    public static array $sections = array();
    public static function register( $file, $slug, $priority, $callback, $metadata = array() ): void {
        self::$sections[ $slug ] = compact( 'priority', 'callback' );
    }
    public static function compose(): string {
        ksort( $GLOBALS['actions']['datamachine_sections'] );
        foreach ( $GLOBALS['actions']['datamachine_sections'] as $callbacks ) {
            foreach ( $callbacks as $callback ) { $callback(); }
        }
        uasort( self::$sections, static fn( $a, $b ) => $a['priority'] <=> $b['priority'] );
        return implode( "\n\n", array_map( static fn( $section ) => (string) call_user_func( $section['callback'] ), self::$sections ) );
    }
}
class_alias( 'IntegrationSectionRegistry', 'DataMachine\\Engine\\AI\\SectionRegistry' );

// Must load before normal plugins, as WordPress loads mu-plugins.
require $argv[1];

    // Reproduce normal plugin load: Data Machine and Intelligence resolve the
    // host-selected transport while registering their guidance.
add_action( 'datamachine_sections', static function () {
    $wp = apply_filters( 'datamachine_wp_cli_cmd', 'wp --path=/path/to/site' );
    IntegrationSectionRegistry::register( 'AGENTS.md', 'datamachine', 20, static fn() => "## Data Machine\n\n`{$wp} datamachine memory paths fixture`" );
}, 10 );
add_action( 'datamachine_sections', static function () {
    IntegrationSectionRegistry::register( 'AGENTS.md', 'intelligence', 30, static function () {
        $wp = apply_filters( 'datamachine_wp_cli_cmd', 'wp --path=/path/to/site' );
        return "## Intelligence\n\n`{$wp} intelligence search fixture`";
    } );
}, 10 );

$content = IntegrationSectionRegistry::compose();
file_put_contents( $argv[2], $content );
foreach ( array( 'datamachine memory paths fixture', 'intelligence search fixture' ) as $index => $suffix ) {
    if ( ! preg_match( '/`([^`]+ ' . preg_quote( $suffix, '/' ) . ')`/', $content, $matches ) ) {
        fwrite( STDERR, "Missing composed command: {$suffix}\n" );
        exit( 1 );
    }
    file_put_contents( $argv[3 + $index], $matches[1] );
}
PHP

run_case() {
  local name="$1"
  shift
  wp_cli_transport_set "$@"
  agents_md_guidance_sync_wp_cli_transport

  local transport_line action_line
  transport_line=$(grep -n 'BEGIN agents-md-guidance:wp-cli-transport' "$MU_FILE" | cut -d: -f1)
  action_line=$(grep -n "^add_action( 'datamachine_sections'" "$MU_FILE" | cut -d: -f1)
  [ "$transport_line" -lt "$action_line" ] || {
    echo "FAIL: $name transport filter is not registered before plugin section callbacks" >&2
    return 1
  }

  php "$TMP/compose.php" "$MU_FILE" "$TMP/$name-AGENTS.md" "$TMP/$name-dm.cmd" "$TMP/$name-intelligence.cmd"
  grep -F "\`$AGENT_WP --path=/path/to/site datamachine memory paths fixture\`" "$TMP/$name-AGENTS.md" >/dev/null
  grep -F "\`$AGENT_WP --path=/path/to/site intelligence search fixture\`" "$TMP/$name-AGENTS.md" >/dev/null

  diagnostics=$(env -i PATH="$TMP/bin:/usr/bin:/bin" "${WP_CLI_TRANSPORT[@]}" --path=/path/to/site intelligence search fixture 2>&1)
  case "$diagnostics" in
    *'Warning: The --context argument is already registered by another command.'*) ;;
    *) echo "FAIL: $name direct transport no longer reports registration diagnostics" >&2; return 1 ;;
  esac

  env -i PATH="$TMP/bin:/usr/bin:/bin" bash -c "$(<"$TMP/$name-dm.cmd")"
  env -i PATH="$TMP/bin:/usr/bin:/bin" bash -c "$(<"$TMP/$name-intelligence.cmd")"
  result=$(env -i PATH="$TMP/bin:/usr/bin:/bin" bash -c "$(<"$TMP/$name-intelligence.cmd")" 2>&1)
  [ "$result" = $'search result\nWarning: an unrelated command diagnostic.' ] || {
    echo "FAIL: $name agent transport did not isolate registration warnings: $result" >&2
    return 1
  }
}

run_case studio studio wp

# Upgrade an installation written by #521, where the filter lived inside the
# late section-registration callback, and verify it is moved back to file scope.
python3 - "$MU_FILE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text()
begin = content.index("// BEGIN agents-md-guidance:wp-cli-transport")
end_marker = "// END agents-md-guidance:wp-cli-transport"
end = content.index(end_marker, begin) + len(end_marker)
block = "\n".join("    " + line for line in content[begin:end].splitlines())
content = content[:begin] + content[end:].lstrip("\n")
content = content.replace("    // END agents-md-guidance-sections", block + "\n    // END agents-md-guidance-sections")
path.write_text(content)
PY
run_case studio-upgrade studio wp
run_case generic wp

echo "==> upgrade restores AGENTS.md after failed or stale composition"
UPGRADE_TMP="$TMP/upgrade"
mkdir -p "$UPGRADE_TMP/bin"
cat > "$UPGRADE_TMP/bin/wp" <<'SH'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    eval)
      printf '%s\n' "${COMPOSE_GATE:-enabled}"
      exit 0
      ;;
  esac
done
if [ "${1:-}" = "datamachine" ] && [ "${2:-}" = "memory" ] && [ "${3:-}" = "compose" ]; then
  case "${COMPOSE_CASE:-}" in
    partial-fail)
      # Runtime instruction setup composes first. Leave no file there so the
      # phase under test is the first writer of AGENTS.md.
      if [ ! -e "${COMPOSE_COUNT_FILE:-/dev/null}" ]; then touch "$COMPOSE_COUNT_FILE"; exit 0; fi
      printf '%s\n' 'partial compose output' > AGENTS.md
      exit 1
      ;;
    missing-success) printf '%s\n' 'successful compose without provenance'; exit 0 ;;
    stale-success) printf '%s\n' '<!-- wp-coding-agents-provenance: version=old source=commit:stale -->' > AGENTS.md; exit 0 ;;
  esac
fi
exit 0
SH
chmod +x "$UPGRADE_TMP/bin/wp"

assert_upgrade_failure_restores() {
  local name="$1" initial="$2" case_name="$3" site output
  site="$UPGRADE_TMP/$name"
  mkdir -p "$site/wp-content/mu-plugins"
  : > "$site/wp-config.php"
  if [ -n "$initial" ]; then
    printf '%s' "$initial" > "$site/AGENTS.md"
    cp "$site/AGENTS.md" "$site/original"
    : > "$site/compose-count"
  fi
  if output=$(PATH="$UPGRADE_TMP/bin:$PATH" COMPOSE_CASE="$case_name" COMPOSE_COUNT_FILE="$site/compose-count" COMPOSE_GATE=enabled \
    bash "$ROOT_DIR/upgrade.sh" --local --runtime opencode --wp-path "$site" --agents-md-only --skip-plugins 2>&1); then
    echo "FAIL: $name upgrade unexpectedly succeeded" >&2
    exit 1
  fi
  if [ -n "$initial" ]; then
    cmp -s "$site/original" "$site/AGENTS.md" || { echo "FAIL: $name did not restore AGENTS.md byte-for-byte: $output" >&2; exit 1; }
  elif [ -e "$site/AGENTS.md" ]; then
    echo "FAIL: $name left a newly-created partial AGENTS.md: $output" >&2
    exit 1
  fi
}

assert_upgrade_failure_restores partial-compose $'## User guidance\nexact bytes\n' partial-fail
assert_upgrade_failure_restores new-partial-compose '' partial-fail
assert_upgrade_failure_restores missing-provenance-compose $'## User guidance\nexact bytes\n' missing-success
assert_upgrade_failure_restores stale-compose $'## User guidance\nexact bytes\n' stale-success

VERIFY_SITE="$UPGRADE_TMP/verify"
mkdir -p "$VERIFY_SITE/wp-content/mu-plugins"
: > "$VERIFY_SITE/wp-config.php"
printf '%s\n' "$(agents_md_guidance_provenance_markdown)" > "$VERIFY_SITE/wp-content/mu-plugins/wp-coding-agents-agents-md.php"
if VERIFY_OUTPUT=$(PATH="$UPGRADE_TMP/bin:$PATH" COMPOSE_GATE=enabled bash "$ROOT_DIR/verify.sh" --site-path "$VERIFY_SITE" 2>&1); then
  echo "FAIL: verify accepted installed guidance with missing composed provenance" >&2
  exit 1
fi
case "$VERIFY_OUTPUT" in
  *'installed guidance is version='*'not explicitly disabled or unavailable'*) ;;
  *) echo "FAIL: verify did not identify installed-present/composed-missing provenance drift: $VERIFY_OUTPUT" >&2; exit 1 ;;
esac

echo "OK: composed Data Machine and Intelligence guidance uses one executable transport"
