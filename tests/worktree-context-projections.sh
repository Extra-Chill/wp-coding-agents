#!/bin/bash
# Contract test for DMC #907 runtime-owned context projections.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/site/wp-content/mu-plugins" "$TMP/worktree/.git"
export SITE_PATH="$TMP/site" DRY_RUN=false
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
SOURCE_MODE="${SOURCE_MODE:-workspace}"
source "$SCRIPT_DIR/lib/runtime-signature.sh"
log() { :; }
warn() { :; }
UPDATED_ITEMS=()
cat > "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php" <<'PHP'
<?php
defined( 'ABSPATH' ) || exit;
add_filter( 'datamachine_code_worktree_runtime_signatures', function ( $signatures ) {
    // BEGIN runtimes
    // BEGIN runtime:legacy
    $signatures['legacy'] = [ 'session_id' => 'LEGACY_SESSION_ID' ];
    // END runtime:legacy
    // END runtimes
    return $signatures;
} );
PHP
runtime_signature_register opencode '{"run_id":"OPENCODE_RUN_ID"}'
grep -q "datamachine_code_worktree_context_projection_targets" "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
grep -q "BEGIN runtime:legacy" "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"

cat > "$TMP/test.php" <<PHP
<?php
define( 'ABSPATH', '/' );
const ROOT = '$TMP';
function add_filter( \$tag, \$callback, \$priority = 10, \$args = 1 ) { \$GLOBALS['f'][\$tag][] = \$callback; }
function apply_filters( \$tag, \$value, ...\$args ) { foreach ( \$GLOBALS['f'][\$tag] ?? [] as \$callback ) { \$value = \$callback( \$value, ...\$args ); } return \$value; }
function wp_mkdir_p( \$path ) { return is_dir( \$path ) || mkdir( \$path, 0777, true ); }
class WP_Error { public function __construct( \$code, \$message ) {} }
require '$TMP/site/wp-content/mu-plugins/wp-coding-agents-runtimes.php';
\$payload = array( 'agents_md_path' => ROOT . '/site/AGENTS.md' );
file_put_contents( \$payload['agents_md_path'], 'site context' );
\$targets = apply_filters( 'datamachine_code_worktree_context_projection_targets', array(), \$payload );
if ( ! isset( \$targets['claude_local_context'], \$targets['site_agents_md'] ) || '.claude/CLAUDE.local.md' !== \$targets['claude_local_context']['path'] ) { exit( 1 ); }
\$written = \$targets['site_agents_md']['projector']( ROOT . '/worktree', \$payload, \$targets['site_agents_md'] );
if ( ! is_link( ROOT . '/worktree/AGENTS.md' ) || count( \$written ) !== 2 ) { exit( 2 ); }
\$cleanup = apply_filters( 'datamachine_code_worktree_context_projection_cleanup', array() );
\$cleanup['site_agents_md']['cleanup']( ROOT . '/worktree', \$cleanup['site_agents_md'] );
if ( file_exists( ROOT . '/worktree/AGENTS.md' ) || is_link( ROOT . '/worktree/AGENTS.md' ) ) { exit( 3 ); }
mkdir( ROOT . '/worktree/.opencode', 0777, true );
file_put_contents( ROOT . '/worktree/AGENTS.md', 'repo context' );
file_put_contents( ROOT . '/worktree/.opencode/opencode.json', '{"model":"preserve"}' );
\$targets['site_agents_md']['projector']( ROOT . '/worktree', \$payload, \$targets['site_agents_md'] );
\$config = json_decode( file_get_contents( ROOT . '/worktree/.opencode/opencode.json' ), true );
if ( ! in_array( \$payload['agents_md_path'], \$config['instructions'], true ) ) { exit( 4 ); }
\$cleanup['opencode_config']['cleanup']( ROOT . '/worktree', \$cleanup['opencode_config'] );
if ( '{"model":"preserve"}' !== file_get_contents( ROOT . '/worktree/.opencode/opencode.json' ) ) { exit( 5 ); }
echo "OK\n";
PHP

php "$TMP/test.php"
