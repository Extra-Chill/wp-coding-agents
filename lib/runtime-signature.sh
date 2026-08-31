#!/bin/bash
# lib/runtime-signature.sh — Per-runtime worktree session-attribution signature
# writer.
#
# Homeboy's worktree-attribution code captures "origin session"
# metadata when an agent spawns a worktree. Historically DMC hardcoded the
# env-var → field map for each coding-agent runtime it knew about
# (OPENCODE_RUN_ID → opencode_run_id,
# etc.). Per the platform's layer-purity rule, those vendor names do not
# belong in Homeboy's generic lifecycle layer.
#
# Homeboy reads the map from its owning-layer filter:
#
#   apply_filters( 'homeboy_worktree_runtime_signatures', [] )
#
# Each entry is keyed by an opaque runtime ID (a string the integration layer
# chooses, e.g. 'kimaki', 'opencode') and maps subkeys (session_id, thread_id,
# thread_url, run_id, …) to the env var DMC should sniff for that subkey.
#
# wp-coding-agents is the integration layer that knows about kimaki and
# opencode — it installs both, writes systemd units that pass KIMAKI_* /
# OPENCODE_* into the spawned processes, and is the only honest place those
# brand names live. This module owns publishing that knowledge into the
# Homeboy filter via a mu-plugin file.
#
# Resolved file: $SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php
#
# Why a separate mu-plugin file (Option B), not the existing
# wp-coding-agents-channels.php (Option A) and not a wp_option write
# (Option C):
#
#   * Option A bundles two unrelated concerns under a filename that says
#     "channels" — runtime signatures are not channels, they're env-var
#     contracts for a different filter consumer.
#
#   * Option C (`wp option patch insert`) requires runtime WP-CLI execution
#     at install time, which lib/cli-channel.sh explicitly rejected for the
#     CLI-channel registry because DB writes there race against multisite
#     + Redis caching and have been a source of intermittent install
#     failures historically. The same constraint applies here.
#
#   * Option B keeps each mu-plugin doing one thing and matches DMC#416's
#     filter-only API (no get_option fallback required). The mu-plugins/
#     surface growth is a real-but-small paper cut that can be paid down
#     later by consolidating these registries into a single file, separate
#     from this PR.
#
# The file uses the same marker-delimited block pattern as
# lib/cli-channel.sh so each runtime's block can be inserted, replaced, or
# removed idempotently without re-parsing PHP, and so two runtimes (kimaki
# and opencode) can each manage their own block independently.
#
# Public surface:
#   runtime_signature_mu_plugin_path                       — echo file path
#   runtime_signature_ensure_mu_plugin_file                — create stub
#   runtime_signature_register <runtime_id> <signature_json>
#   runtime_signature_unregister <runtime_id>
#
# `signature_json` is a JSON object mapping subkey → env-var name, e.g.:
#   '{"run_id":"OPENCODE_RUN_ID"}'
#
# Honors DRY_RUN (logs intent, makes no changes).

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

# runtime_signature_mu_plugin_path
#
# Print the absolute path of the mu-plugin file. Requires SITE_PATH (set by
# lib/detect.sh during setup/upgrade). Empty + return 1 if SITE_PATH unset.
runtime_signature_mu_plugin_path() {
  if [ -z "${SITE_PATH:-}" ]; then
    return 1
  fi
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
}

# ---------------------------------------------------------------------------
# File scaffolding
# ---------------------------------------------------------------------------

# runtime_signature_ensure_mu_plugin_file
#
# Create the mu-plugin file with the filter scaffold if it does not exist.
# Idempotent — does nothing if the file already exists. The scaffold contains
# a single `add_filter( 'homeboy_worktree_runtime_signatures', … )`
# callback whose body is the marker-delimited region that runtimes write into.
runtime_signature_ensure_mu_plugin_file() {
  local file
  file="$(runtime_signature_mu_plugin_path)" || {
    warn "  runtime_signature_ensure_mu_plugin_file: SITE_PATH not set — skipping"
    return 1
  }

  if [ -f "$file" ]; then
    runtime_signature_migrate_mu_plugin "$file"
    runtime_context_projection_upgrade_mu_plugin "$file"
    return 0
  fi

  local dir="${file%/*}"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mkdir -p $dir"
    echo -e "${BLUE}[dry-run]${NC} Would write runtime-signature mu-plugin to $file"
    return 0
  fi

  mkdir -p "$dir"

  # Write the scaffold, then normalize mode/group regardless of the
  # caller's umask or identity (root cron/systemd contexts default to
  # umask 0077, which strips the world-read bit PHP-FPM needs — issue
  # #133 — and root/opencode/www-data writers each leave a different
  # owner, which without a shared group-writable mode breaks the next
  # writer — issue #258).
  cat > "$file" <<'PHP'
<?php
/**
 * Plugin Name: wp-coding-agents — Worktree runtime registry
 * Description: Registers per-coding-agent-runtime env-var signatures and
 *              worktree context projections consumed by Homeboy.
 *              Runtime paths, config schemas, markers, and cleanup remain in
 *              this integration layer. Managed by wp-coding-agents.
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

if ( ! class_exists( 'WpCodingAgents_Worktree_Context_Projections', false ) ) {
	class WpCodingAgents_Worktree_Context_Projections {
		private const LOCAL_CONTEXT = '.claude/CLAUDE.local.md';
		private const LEGACY_CONTEXT = '.opencode/AGENTS.local.md';
		private const AGENTS_PATH = 'AGENTS.md';
		private const AGENTS_MARKER = '.datamachine/AGENTS.md.source';
		private const CONFIG_PATH = '.opencode/opencode.json';
		private const CONFIG_MARKER = '.datamachine/opencode-config.json.previous';

		public static function register(): void {
			add_filter( 'homeboy_worktree_context_projection_targets', array( self::class, 'targets' ), 10, 2 );
			add_filter( 'homeboy_worktree_context_projection_cleanup', array( self::class, 'cleanup' ) );
		}

		public static function targets( $targets, array $payload = array() ): array {
			$targets = is_array( $targets ) ? $targets : array();
			$targets['claude_local_context'] = array( 'path' => self::LOCAL_CONTEXT, 'exclude' => true );
			$targets['site_agents_md'] = array(
				'projector' => array( self::class, 'project_agents' ),
				'exclude_paths' => array( self::AGENTS_PATH, self::AGENTS_MARKER, self::CONFIG_PATH, self::CONFIG_MARKER ),
			);
			return $targets;
		}

		public static function cleanup( $cleanup ): array {
			$cleanup = is_array( $cleanup ) ? $cleanup : array();
			$cleanup['site_agents_md'] = array( 'cleanup' => array( self::class, 'cleanup_agents' ) );
			$cleanup['opencode_config'] = array( 'cleanup' => array( self::class, 'cleanup_config' ) );
			$cleanup['claude_local_context'] = array( 'paths' => array( self::LOCAL_CONTEXT ) );
			$cleanup['legacy_opencode'] = array( 'paths' => array( self::LEGACY_CONTEXT ) );
			return $cleanup;
		}

		public static function project_agents( string $worktree, array $payload ): array|WP_Error {
			$source = (string) ( $payload['agents_md_path'] ?? '' );
			if ( '' === $source || ! is_file( $source ) ) { return array(); }
			if ( str_starts_with( $source, '/wordpress/' ) || file_exists( $worktree . '/' . self::AGENTS_PATH ) || is_link( $worktree . '/' . self::AGENTS_PATH ) ) {
				return self::project_config( $worktree, str_starts_with( $source, '/wordpress/' ) ? $worktree . '/' . self::LOCAL_CONTEXT : $source );
			}
			$target = $worktree . '/' . self::AGENTS_PATH;
			$marker = $worktree . '/' . self::AGENTS_MARKER;
			if ( ! self::mkdir( dirname( $marker ) ) || ! symlink( $source, $target ) || false === file_put_contents( $marker, "symlink\n" . $source . "\n" ) ) {
				if ( is_link( $target ) ) { unlink( $target ); }
				return new WP_Error( 'agents_md_projection_failed', 'Failed to project site AGENTS.md.' );
			}
			return array( $target, $marker );
		}

		private static function project_config( string $worktree, string $source ): array|WP_Error {
			if ( ! is_file( $source ) ) { return array(); }
			$config = $worktree . '/' . self::CONFIG_PATH;
			$marker = $worktree . '/' . self::CONFIG_MARKER;
			$previous = is_file( $config ) ? (string) file_get_contents( $config ) : '';
			$data = '' === trim( $previous ) ? array( '$schema' => 'https://opencode.ai/config.json', 'instructions' => array() ) : json_decode( $previous, true );
			if ( ! is_array( $data ) ) { return new WP_Error( 'opencode_config_invalid', 'Cannot add site AGENTS.md to invalid OpenCode config.' ); }
			$instructions = is_array( $data['instructions'] ?? null ) ? $data['instructions'] : array();
			if ( ! in_array( $source, $instructions, true ) ) { $instructions[] = $source; }
			$data['instructions'] = array_values( $instructions );
			if ( ! self::mkdir( dirname( $config ) ) || ! self::mkdir( dirname( $marker ) ) || false === file_put_contents( $marker, json_encode( array( 'existed' => is_file( $config ), 'content' => $previous ), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) . "\n" ) || false === file_put_contents( $config, json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) . "\n" ) ) {
				return new WP_Error( 'opencode_config_projection_failed', 'Failed to project OpenCode config.' );
			}
			return array( $marker, $config );
		}

		public static function cleanup_agents( string $worktree ): array {
			$removed = array(); $target = $worktree . '/' . self::AGENTS_PATH; $marker = $worktree . '/' . self::AGENTS_MARKER;
			$lines = is_file( $marker ) ? preg_split( '/\r\n|\r|\n/', trim( (string) file_get_contents( $marker ) ) ) : array();
			if ( is_link( $target ) && isset( $lines[1] ) && readlink( $target ) === $lines[1] ) { unlink( $target ); $removed[] = $target; }
			elseif ( 'inline' === ( $lines[0] ?? '' ) && is_file( $target ) ) { unlink( $target ); $removed[] = $target; }
			if ( is_file( $marker ) ) { unlink( $marker ); $removed[] = $marker; }
			return $removed;
		}

		public static function cleanup_config( string $worktree ): array {
			$removed = array(); $config = $worktree . '/' . self::CONFIG_PATH; $marker = $worktree . '/' . self::CONFIG_MARKER;
			if ( ! is_file( $marker ) ) { return $removed; }
			$data = json_decode( (string) file_get_contents( $marker ), true );
			if ( is_array( $data ) && ! empty( $data['existed'] ) ) { file_put_contents( $config, (string) ( $data['content'] ?? '' ) ); }
			elseif ( is_file( $config ) ) { unlink( $config ); $removed[] = $config; }
			unlink( $marker ); $removed[] = $marker;
			return $removed;
		}

		private static function mkdir( string $path ): bool { return is_dir( $path ) || wp_mkdir_p( $path ); }
	}
}

WpCodingAgents_Worktree_Context_Projections::register();

/**
 * Registers per-coding-agent-runtime env-var signatures that
 *              Homeboy reads when capturing origin-session
 *              metadata for spawned worktrees. wp-coding-agents installs
 *              kimaki and opencode and is the only layer that legitimately
 *              knows the brand-specific env-var names those runtimes set;
 *              this file publishes that knowledge so Homeboy stays runtime-
 *              agnostic. Managed by wp-coding-agents runtime/bridge
 *              installers — do not edit by hand. Runtime install/upgrade
 *              rewrites the marker blocks below; runtime/bridge removal
 *              removes them.
 *
 * Each runtime contributes a marker-delimited PHP block of the form:
 *
 *   // BEGIN runtime:<runtime_id>
 *   $signatures['<runtime_id>'] = [
 *       'session_id' => 'EXAMPLE_SESSION_ID',
 *       'thread_id'  => 'EXAMPLE_THREAD_ID',
 *   ];
 *   // END runtime:<runtime_id>
 *
 * The subkey set is open — Homeboy does not validate against a closed schema.
 * Conventional subkeys are: session_id, thread_id, thread_url, run_id.
 * Integrations may add more.
 *
 * Filter contract: homeboy_worktree_runtime_signatures.
 *
 * @package wp-coding-agents
 */

add_filter( 'homeboy_worktree_runtime_signatures', function ( $signatures ) {
    if ( ! is_array( $signatures ) ) {
        $signatures = [];
    }

    // BEGIN runtimes
    // END runtimes

    return $signatures;
} );
PHP

  service_file_normalize_perms "$file"

  log "  Wrote runtime-signature mu-plugin scaffold: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("created $file")
  fi
}

# Migrate the generated registry in place. Runtime marker blocks are owned by
# individual installers and remain byte-for-byte intact.
runtime_signature_migrate_mu_plugin() {
  local file="$1"
  grep -q "datamachine""_code_" "$file" || return 0
  [ "${DRY_RUN:-false}" = true ] && { echo -e "${BLUE}[dry-run]${NC} Would migrate retired runtime hooks in $file"; return 0; }
  python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
legacy = "datamachine" + "_code_worktree_"
content = content.replace(legacy + "runtime_signatures", "homeboy_worktree_runtime_signatures")
content = content.replace(legacy + "context_projection_targets", "homeboy_worktree_context_projection_targets")
content = content.replace(legacy + "context_projection_cleanup", "homeboy_worktree_context_projection_cleanup")
path.write_text(content, encoding="utf-8")
PY
  service_file_normalize_perms "$file"
  log "  Migrated runtime registry hooks in $file"
}

# Upgrade existing runtime-registry mu-plugins in place without disturbing the
# marker-delimited runtime signature blocks that individual installers own.
runtime_context_projection_upgrade_mu_plugin() {
  local file="$1"
  grep -q "homeboy_worktree_context_projection_targets" "$file" && return 0
  [ "${DRY_RUN:-false}" = true ] && { echo -e "${BLUE}[dry-run]${NC} Would add worktree context projections to $file"; return 0; }

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  # Render the current scaffold in an isolated temporary site, then retain the
  # existing runtime blocks while replacing the old signature-only wrapper.
  local old_site="${SITE_PATH:-}"
  local scaffold_root
  scaffold_root=$(mktemp -d)
  SITE_PATH="$scaffold_root"
  mkdir -p "$SITE_PATH/wp-content/mu-plugins"
  local generated="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php"
  DRY_RUN=false runtime_signature_ensure_mu_plugin_file
  python3 - "$file" "$generated" > "$tmp" <<'PY'
import re, sys
old, generated = (open(path, encoding='utf-8').read() for path in sys.argv[1:])
blocks = '\n'.join(re.findall(r'    // BEGIN runtime:.*?\n.*?\n    // END runtime:.*?(?=\n|$)', old, re.S))
generated = re.sub(r'    // BEGIN runtimes\n    // END runtimes', '    // BEGIN runtimes\n' + (blocks + '\n' if blocks else '') + '    // END runtimes', generated)
print(generated, end='')
PY
  mv "$tmp" "$file"
  rm -rf "$scaffold_root"
  SITE_PATH="$old_site"
  service_file_normalize_perms "$file"
  log "  Added worktree context projections to $file"
}

# ---------------------------------------------------------------------------
# Block render
# ---------------------------------------------------------------------------

# _runtime_signature_render_block <runtime_id> <signature_json>
#
# Print the marker-delimited PHP block for a single runtime, including
# surrounding BEGIN/END markers, indented to match the scaffold's filter
# body. The signature JSON is converted to a PHP array literal of
# subkey => 'ENV_VAR_NAME' pairs.
_runtime_signature_render_block() {
  local runtime_id="$1" signature_json="$2"
  local esc_runtime_id esc_signature
  esc_runtime_id=$(_runtime_signature_php_escape "$runtime_id")
  esc_signature=$(_runtime_signature_json_to_php_map "$signature_json")

  cat <<PHP
    // BEGIN runtime:${esc_runtime_id}
    \$signatures['${esc_runtime_id}'] = ${esc_signature};
    // END runtime:${esc_runtime_id}
PHP
}

# _runtime_signature_php_escape <string>
#
# Escape a string for inclusion inside a PHP single-quoted literal.
_runtime_signature_php_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf '%s' "$s"
}

# _runtime_signature_json_to_php_map <json_object_literal>
#
# Convert a JSON object like {"run_id":"OPENCODE_RUN_ID"} into a
# PHP associative array literal [ 'run_id' => 'OPENCODE_RUN_ID' ].
# Uses python3 (every host that runs wp-coding-agents already depends on
# python3 — see lib/repair-opencode-json.py and runtimes/opencode.sh).
# Keys are emitted in the order they appear in the JSON for stable diffs.
_runtime_signature_json_to_php_map() {
  local json="$1"
  python3 - "$json" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")
if not isinstance(obj, dict):
    sys.stderr.write("runtime signature must be a JSON object\n")
    sys.exit(1)
if not obj:
    print("[]")
    sys.exit(0)
parts = []
for k, v in obj.items():
    if not isinstance(k, str) or not isinstance(v, str):
        sys.stderr.write("runtime signature keys and values must be strings\n")
        sys.exit(1)
    parts.append("'" + esc(k) + "' => '" + esc(v) + "'")
print("[ " + ", ".join(parts) + " ]")
PY
}

# ---------------------------------------------------------------------------
# Register / unregister
# ---------------------------------------------------------------------------

# runtime_signature_register <runtime_id> <signature_json>
#
# Upsert <runtime_id>'s block in the mu-plugin file. Idempotent: re-running
# with the same arguments leaves the file unchanged; re-running with a
# different signature replaces just that runtime's block. Other runtimes'
# blocks are preserved.
runtime_signature_register() {
  local runtime_id="$1" signature_json="$2"

  if [ -z "$runtime_id" ] || [ -z "$signature_json" ]; then
    warn "  runtime_signature_register: missing required args (runtime_id=$runtime_id signature=$signature_json)"
    return 1
  fi

  local file
  file="$(runtime_signature_mu_plugin_path)" || {
    warn "  runtime_signature_register: SITE_PATH not set — skipping runtime '$runtime_id'"
    return 1
  }

  runtime_signature_ensure_mu_plugin_file || return 1

  local new_block
  new_block=$(_runtime_signature_render_block "$runtime_id" "$signature_json")

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would register runtime signature '$runtime_id' in $file"
    echo -e "${BLUE}[dry-run]${NC} Block:"
    echo "$new_block" | sed 's/^/    /'
    return 0
  fi

  if _runtime_signature_block_matches "$file" "$runtime_id" "$new_block"; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _runtime_signature_rewrite "$file" "$runtime_id" "$new_block" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  # mktemp creates the tmp file at mode 0600, so mv preserves that, and mv
  # also preserves the tmp file's own owner rather than the destination's —
  # self-heal both mode and group on every write (issue #133, issue #258).
  service_file_normalize_perms "$file"
  log "  Registered runtime signature '$runtime_id' in $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("runtime signature: $runtime_id")
  fi
}

# runtime_signature_unregister <runtime_id>
#
# Remove <runtime_id>'s block from the mu-plugin file. No-op if the file
# does not exist, or if the block is not present. Other runtimes' blocks
# are preserved.
runtime_signature_unregister() {
  local runtime_id="$1"
  if [ -z "$runtime_id" ]; then
    warn "  runtime_signature_unregister: missing runtime_id"
    return 1
  fi

  local file
  file="$(runtime_signature_mu_plugin_path)" || {
    return 0
  }
  [ -f "$file" ] || return 0

  if ! grep -q "// BEGIN runtime:${runtime_id}\$" "$file"; then
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would unregister runtime signature '$runtime_id' from $file"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _runtime_signature_rewrite "$file" "$runtime_id" "" > "$tmp"
  mv "$tmp" "$file"
  service_file_normalize_perms "$file"
  log "  Unregistered runtime signature '$runtime_id' from $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("runtime signature removed: $runtime_id")
  fi
}

# _runtime_signature_block_matches <file> <runtime_id> <new_block>
#
# Return 0 if the existing block for <runtime_id> in <file> already equals
# <new_block> verbatim; otherwise 1. Used to short-circuit no-op rewrites.
_runtime_signature_block_matches() {
  local file="$1" runtime_id="$2" new_block="$3"
  local existing
  existing=$(awk -v rid="$runtime_id" '
    $0 == "    // BEGIN runtime:" rid { capturing=1 }
    capturing { print }
    $0 == "    // END runtime:" rid { exit }
  ' "$file")
  [ "$existing" = "$new_block" ]
}

# _runtime_signature_rewrite <file> <runtime_id> <new_block>
#
# Stream <file> to stdout, replacing the existing block for <runtime_id>
# with <new_block>, or inserting <new_block> immediately before the
# `// END runtimes` marker if no block for <runtime_id> exists yet. Empty
# <new_block> removes the runtime's block entirely (used by unregister).
_runtime_signature_rewrite() {
  local file="$1" runtime_id="$2" new_block="$3"
  RUNTIME_SIGNATURE_NEW_BLOCK="$new_block" python3 - "$file" "$runtime_id" <<'PY'
import os, sys

file_path, runtime_id = sys.argv[1], sys.argv[2]
new_block = os.environ.get("RUNTIME_SIGNATURE_NEW_BLOCK", "")
begin_marker = f"    // BEGIN runtime:{runtime_id}"
end_marker = f"    // END runtime:{runtime_id}"

with open(file_path, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

inserted = False
skipping = False
out = []

for line in lines:
    if line == begin_marker:
        skipping = True
        if new_block:
            out.extend(new_block.splitlines())
            inserted = True
        continue

    if skipping:
        if line == end_marker:
            skipping = False
        continue

    if not inserted and line == "    // END runtimes":
        if new_block:
            out.extend(new_block.splitlines())
            inserted = True

    out.append(line)

sys.stdout.write("\n".join(out))
sys.stdout.write("\n")
PY
}
