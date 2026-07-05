#!/bin/bash
# tests/homeboy-agents-md.sh — Regression coverage for the presence-gated
# Homeboy CLI command map (issues #208, #254).
#
# Since #254 the section is registered as a LIVE-enumeration PHP block: the
# mu-plugin callback shells out to `homeboy --help` at AGENTS.md compose
# time and parses the Commands: block in PHP. The command list is therefore
# never baked into the mu-plugin at setup time.
#
# Invariants covered:
#   - homeboy present  -> the `homeboy-cli` section is registered with a
#                         callback that ENUMERATES `homeboy --help` live;
#                         the rendered markdown matches the live binary.
#   - homeboy absent   -> complete no-op: no section, no stub, no warning.
#   - live refresh     -> after a `homeboy upgrade` (simulated by swapping
#                         the stub binary's --help output and bumping its
#                         mtime + --version), re-invoking the SAME mu-plugin
#                         callback picks up the new command surface WITHOUT
#                         re-running the wp-coding-agents setup/sync path.
#                         This is the #254 regression: previously the section
#                         was a frozen string and the trigger gap meant the
#                         map desynced until the next `./upgrade.sh`.
#
# We mock `homeboy` on PATH so the test never depends on a real install and
# the command list is deterministic.
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

# --- Mock homeboy --------------------------------------------------------
# A fake `homeboy --help` that mimics the real clap-rendered command table,
# including the meta `help`/`list` commands (which must be dropped) and a
# wrapped continuation line (which must be ignored).
MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/homeboy" <<'SH'
#!/bin/bash
if [ "$1" = "--help" ]; then
  cat <<'HELP'
Headless automation for agentic software engineering workflows

Usage: homeboy [OPTIONS] <COMMAND>

Commands:
  deploy    Deploy components to remote server
  release   Plan release workflows
  triage    Read-only attention report for components, projects, fleets, and rigs
  status    Actionable component status overview
  list      List available commands (alias for --help)
  help      Print this message or the help of the given subcommand(s)

Options:
  -h, --help     Print help
  -V, --version  Print version
HELP
  exit 0
fi
exit 0
SH
chmod +x "$MOCKBIN/homeboy"

# --- Present case --------------------------------------------------------
echo "==> homeboy present: emit generated CLI command map"
(
  export PATH="$MOCKBIN:$PATH"
  agents_md_guidance_sync_homeboy_cli
)

assert_php_lint "$MU_FILE" "guidance mu-plugin parses with php -l (present)"

if grep -q "BEGIN agents-md-guidance:homeboy-cli" "$MU_FILE"; then
  echo "  ok   homeboy-cli block present"
else
  echo "  FAIL homeboy-cli block missing"
  FAILED=$((FAILED + 1))
fi

echo "==> inspect generated section via datamachine_sections action"
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
    function add_action( \$tag, \$callback, \$priority = 10 ) {
        \$GLOBALS['actions'][\$tag][] = \$callback;
    }
    // The live enumerator uses the WP transient API for its cache. Provide
    // no-op stubs so each invocation re-shells-out (the cache path itself is
    // exercised separately by the cache-hit unit below).
    function get_transient( \$k ) { return false; }
    function set_transient( \$k, \$v, \$t ) { return true; }
    require '$MU_FILE';
    foreach ( \$GLOBALS['actions']['datamachine_sections'] ?? [] as \$callback ) {
        \$callback();
    }
    \$call = \DataMachine\Engine\AI\SectionRegistry::\$calls['homeboy-cli'] ?? null;
    \$content = \$call ? (string) call_user_func( \$call[3] ) : '';
    echo json_encode([
        'filename' => \$call[0] ?? null,
        'slug' => \$call[1] ?? null,
        'priority' => \$call[2] ?? null,
        'label' => \$call[4]['label'] ?? null,
        'owner' => \$call[4]['owner'] ?? null,
        'freshness' => \$call[4]['freshness'] ?? null,
        'has_live_freshness' => ( \$call[4]['freshness'] ?? '' ) === 'live',
        'has_live_intro' => str_contains( \$content, 'generated live from \`homeboy --help\` at AGENTS.md compose time' ),
        'no_false_refresh_prose' => ! str_contains( \$content, 'refreshes whenever homeboy is upgraded' ),
        'has_deploy' => str_contains( \$content, '- \`homeboy deploy\` — Deploy components to remote server' ),
        'has_release' => str_contains( \$content, '- \`homeboy release\` — Plan release workflows' ),
        'has_triage' => str_contains( \$content, '- \`homeboy triage\` — Read-only attention report' ),
        'has_status' => str_contains( \$content, '- \`homeboy status\` — Actionable component status overview' ),
        'has_orchestrator_intro' => str_contains( \$content, 'Homeboy is the host orchestrator binary' ),
        'has_common_entrypoints' => str_contains( \$content, 'Common entrypoints:' ),
        'drops_help_meta' => ! str_contains( \$content, 'homeboy help' ),
        'drops_list_meta' => ! str_contains( \$content, 'homeboy list' ),
        'has_discover_footer' => str_contains( \$content, 'Discover everything: \`homeboy --help\`' ),
        'has_per_command_footer' => str_contains( \$content, 'homeboy <command> --help' ),
    ]);
}
PHP

RESULT=$(PATH="$MOCKBIN:$PATH" php "$SHIM")
EXPECTED='{"filename":"AGENTS.md","slug":"homeboy-cli","priority":34,"label":"Homeboy CLI","owner":"wp-coding-agents","freshness":"live","has_live_freshness":true,"has_live_intro":true,"no_false_refresh_prose":true,"has_deploy":true,"has_release":true,"has_triage":true,"has_status":true,"has_orchestrator_intro":true,"has_common_entrypoints":true,"drops_help_meta":true,"drops_list_meta":true,"has_discover_footer":true,"has_per_command_footer":true}'
assert_eq "$RESULT" "$EXPECTED" "SectionRegistry receives live Homeboy CLI map"

echo "==> re-sync with homeboy present (idempotent)"
HASH_BEFORE=$(md5sum "$MU_FILE" | cut -d' ' -f1)
(
  export PATH="$MOCKBIN:$PATH"
  agents_md_guidance_sync_homeboy_cli
)
HASH_AFTER=$(md5sum "$MU_FILE" | cut -d' ' -f1)
assert_eq "$HASH_AFTER" "$HASH_BEFORE" "file unchanged on re-sync"

# --- Live refresh (issue #254 regression) --------------------------------
# The defining property of the live-at-compose fix: a `homeboy upgrade` that
# changes the command surface is picked up by re-invoking the SAME mu-plugin
# section callback — NO second wp-coding-agents sync required. The previous
# static-bake design failed this exact scenario.
echo "==> live refresh: simulate homeboy upgrade, re-invoke callback, no setup re-run"

# Swap the stub binary to a "newer" homeboy that adds a `fuzz` command and
# drops `triage`, and bump its version string. Also bump mtime by touching
# the file with a future timestamp so the cache key flips even if the
# version-keyed path were ever removed.
cat > "$MOCKBIN/homeboy" <<'SH'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "homeboy 0.900.1+upgraded"
  exit 0
fi
if [ "$1" = "--help" ]; then
  cat <<'HELP'
Headless automation for agentic software engineering workflows

Usage: homeboy [OPTIONS] <COMMAND>

Commands:
  deploy    Deploy components to remote server
  release   Plan release workflows
  status    Actionable component status overview
  fuzz      Fuzz test components
  list      List available commands (alias for --help)
  help      Print this message or the help of the given subcommand(s)

Options:
  -h, --help     Print help
  -V, --version  Print version
HELP
  exit 0
fi
exit 0
SH
chmod +x "$MOCKBIN/homeboy"
touch -d '+2 seconds' "$MOCKBIN/homeboy"

LIVE_SHIM="$TMP/live-shim.php"
cat > "$LIVE_SHIM" <<PHP
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
    function add_action( \$tag, \$callback, \$priority = 10 ) {
        \$GLOBALS['actions'][\$tag][] = \$callback;
    }
    function get_transient( \$k ) { return false; }
    function set_transient( \$k, \$v, \$t ) { return true; }
    require '$MU_FILE';
    foreach ( \$GLOBALS['actions']['datamachine_sections'] ?? [] as \$callback ) {
        \$callback();
    }
    \$call = \DataMachine\Engine\AI\SectionRegistry::\$calls['homeboy-cli'] ?? null;
    \$content = \$call ? (string) call_user_func( \$call[3] ) : '';
    echo json_encode([
        'has_fuzz'        => str_contains( \$content, '- \`homeboy fuzz\` — Fuzz test components' ),
        'has_deploy'      => str_contains( \$content, '- \`homeboy deploy\` — Deploy components to remote server' ),
        'dropped_triage'  => ! str_contains( \$content, 'homeboy triage' ),
        'version_reflected' => str_contains( \$content, 'homeboy fuzz' ),
    ]);
}
PHP

LIVE_RESULT=$(PATH="$MOCKBIN:$PATH" php "$LIVE_SHIM")
LIVE_EXPECTED='{"has_fuzz":true,"has_deploy":true,"dropped_triage":true,"version_reflected":true}'
assert_eq "$LIVE_RESULT" "$LIVE_EXPECTED" "live refresh picks up homeboy upgrade without setup re-run"

# --- Cache hit path ------------------------------------------------------
# The transient cache must short-circuit the shell-out when a cached render
# is present. Verify by returning a marker string from get_transient and
# asserting the callback returns it verbatim.
echo "==> cache hit: get_transient short-circuits the shell-out"
CACHE_SHIM="$TMP/cache-shim.php"
cat > "$CACHE_SHIM" <<PHP
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
    function add_action( \$tag, \$callback, \$priority = 10 ) {
        \$GLOBALS['actions'][\$tag][] = \$callback;
    }
    function get_transient( \$k ) { return 'CACHED_MARKER_VALUE'; }
    function set_transient( \$k, \$v, \$t ) { return true; }
    require '$MU_FILE';
    foreach ( \$GLOBALS['actions']['datamachine_sections'] ?? [] as \$callback ) {
        \$callback();
    }
    \$call = \DataMachine\Engine\AI\SectionRegistry::\$calls['homeboy-cli'] ?? null;
    \$content = \$call ? (string) call_user_func( \$call[3] ) : '';
    echo json_encode([ 'returned_cached' => \$content === 'CACHED_MARKER_VALUE' ]);
}
PHP
CACHE_RESULT=$(PATH="$MOCKBIN:$PATH" php "$CACHE_SHIM")
CACHE_EXPECTED='{"returned_cached":true}'
assert_eq "$CACHE_RESULT" "$CACHE_EXPECTED" "transient cache short-circuits live enumeration"

# --- Absent case ---------------------------------------------------------
echo "==> homeboy absent: complete no-op (section removed, no stub)"
# Build a sandbox bin dir that has the coreutils the registry needs (grep,
# mktemp, mv, cmp, chmod, python3, md5sum) but deliberately NO homeboy, then
# point PATH at it alone. `command -v homeboy` must fail while the rest of the
# helper still functions — proving the absence path is a true no-op, not a
# crash, even on a host where homeboy happens to be installed elsewhere.
SANDBIN="$TMP/sandbin"
mkdir -p "$SANDBIN"
for tool in grep mktemp mv cmp chmod python3 md5sum cat sed awk rm cut stat; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$SANDBIN/$tool"
done
(
  export PATH="$SANDBIN"
  if command -v homeboy >/dev/null 2>&1; then
    echo "  FAIL test setup: homeboy still resolvable on sandboxed PATH"
    exit 1
  fi
  agents_md_guidance_sync_homeboy_cli
) || FAILED=$((FAILED + 1))

if grep -q "BEGIN agents-md-guidance:homeboy-cli" "$MU_FILE"; then
  echo "  FAIL homeboy-cli block still present when homeboy absent"
  FAILED=$((FAILED + 1))
else
  echo "  ok   homeboy-cli block removed when homeboy absent"
fi

if grep -qi "homeboy" "$MU_FILE" && grep -qi "not installed\|unavailable\|stub" "$MU_FILE"; then
  echo "  FAIL emitted an absent-homeboy stub instead of a no-op"
  FAILED=$((FAILED + 1))
else
  echo "  ok   no absent-homeboy stub emitted"
fi

assert_php_lint "$MU_FILE" "post-no-op file parses with php -l"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all Homeboy CLI command-map assertions passed"
