#!/bin/bash
# lib/cli-channel.sh — Per-bridge CLI-channel config writer.
#
# Each chat bridge in bridges/<name>.sh exposes a CLI surface that can deliver
# messages to a recipient on its platform (kimaki → Discord, cc-connect →
# multi-platform, opencode-telegram → Telegram). Data Machine Code's generic
# CLI transport runtime (Extra-Chill/data-machine-code#412) shells those CLIs
# on behalf of the `agents/dispatch-message` ability, but only if it can
# discover a channel definition mapping `<channel-name>` → command + argv.
#
# This module owns that discovery surface. It writes a mu-plugin file in the
# target WordPress install that registers each bridge's channel entry via the
# `datamachine_code_cli_channels` filter. Each bridge install/sync calls
# cli_channel_register; each bridge uninstall calls cli_channel_unregister.
#
# Design choices:
#
#   * mu-plugins file (not a wp_option write). File-based so an operator can
#     `cat` it and see exactly what the agent will spawn. Always loaded, no
#     activation step. Survives plugin churn. Matches how the rest of
#     wp-coding-agents drops config on disk (/opt/kimaki-config/, etc.) and
#     keeps install-time WP_CLI dependence out of the chat-bridge install
#     flow — DB writes there race against multisite + Redis caching and have
#     been a source of intermittent install failures historically.
#
#   * Marker-delimited blocks (`// BEGIN bridge:<name>` … `// END
#     bridge:<name>`) so each bridge's block can be inserted, replaced, or
#     removed idempotently without re-parsing PHP. Same idea as the
#     well-trodden `wp-config.php` / `/etc/hosts` block-marker pattern.
#
#   * Pure-bash with awk for in-place edits. No PHP or wp-cli required —
#     this script runs inside setup.sh / upgrade.sh and may not have a
#     running WordPress to invoke. The mu-plugin file is just text on disk.
#
# Resolved file: $SITE_PATH/wp-content/mu-plugins/wp-coding-agents-channels.php
#
# Public surface:
#   cli_channel_mu_plugin_path                 — echo resolved file path
#   cli_channel_ensure_mu_plugin_file          — create stub if missing
#   cli_channel_register <name> <command> \
#       <args_json> [detach] [timeout]         — upsert a bridge's block
#   cli_channel_unregister <name>              — remove a bridge's block
#
# `args_json` is a JSON array literal (e.g. '["send","--channel","{recipient}",
# "--prompt","{message}"]'). Substitution tokens supported by the DMC runtime:
#   {recipient}  — the bridge-specific target identifier (see per-bridge docs)
#   {message}    — the message body to deliver
#
# Honors DRY_RUN (logs intent, makes no changes).

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

# cli_channel_mu_plugin_path
#
# Print the absolute path of the mu-plugin file. Requires SITE_PATH (set by
# lib/detect.sh during setup/upgrade). Empty + return 1 if SITE_PATH unset.
cli_channel_mu_plugin_path() {
  if [ -z "${SITE_PATH:-}" ]; then
    return 1
  fi
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-channels.php"
}

# ---------------------------------------------------------------------------
# File scaffolding
# ---------------------------------------------------------------------------

# cli_channel_ensure_mu_plugin_file
#
# Create the mu-plugin file with the filter scaffold if it does not exist.
# Idempotent — does nothing if the file already exists. The scaffold contains
# a single `add_filter( 'datamachine_code_cli_channels', … )` callback whose
# body is the marker-delimited region that bridges write into.
#
# The PHP closure walks the existing $channels array, applies each
# // BEGIN/END marker block in source order, and returns the merged map. If
# DMC's CLI runtime is not loaded (no filter consumers), the array is built
# and discarded — no harm.
cli_channel_ensure_mu_plugin_file() {
  local file
  file="$(cli_channel_mu_plugin_path)" || {
    warn "  cli_channel_ensure_mu_plugin_file: SITE_PATH not set — skipping"
    return 1
  }

  if [ -f "$file" ]; then
    return 0
  fi

  local dir="${file%/*}"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mkdir -p $dir"
    echo -e "${BLUE}[dry-run]${NC} Would write CLI-channel mu-plugin to $file"
    return 0
  fi

  mkdir -p "$dir"

  # Write the scaffold, then force mode 0644 regardless of the caller's
  # umask (root cron/systemd contexts default to 0077 which strips the
  # world-read bit PHP-FPM needs — see issue #133).
  cat > "$file" <<'PHP'
<?php
/**
 * Plugin Name: wp-coding-agents — CLI channel registry
 * Description: Registers chat bridges installed by wp-coding-agents as CLI
 *              channels for the Data Machine Code generic CLI transport
 *              runtime, which backs the agents/dispatch-message ability.
 *              Managed by wp-coding-agents bridge installers — do not edit
 *              by hand. Bridge install/upgrade rewrites the marker blocks
 *              below; bridge uninstall removes them.
 *
 * Each bridge contributes a marker-delimited PHP block of the form:
 *
 *   // BEGIN bridge:<name>
 *   $channels['<name>'] = [
 *       'command' => '/absolute/path/to/cli',
 *       'args'    => [ 'send', '--channel', '{recipient}', '--prompt', '{message}' ],
 *       'detach'  => true,
 *       'timeout' => 600,
 *   ];
 *   // END bridge:<name>
 *
 * Substitution tokens are resolved by the DMC CLI runtime at dispatch time:
 *   {recipient} — bridge-specific target identifier (see bridge docs).
 *   {message}   — the message body delivered by agents/dispatch-message.
 *
 * Filter contract: Extra-Chill/data-machine-code#412.
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

add_filter( 'datamachine_code_cli_channels', function ( $channels ) {
    if ( ! is_array( $channels ) ) {
        $channels = [];
    }

    // BEGIN bridges
    // END bridges

    return $channels;
} );
PHP

  chmod 0644 "$file"

  log "  Wrote CLI-channel mu-plugin scaffold: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("created $file")
  fi
}

# ---------------------------------------------------------------------------
# Block render
# ---------------------------------------------------------------------------

# _cli_channel_render_block <name> <command> <args_json> <detach> <timeout>
#
# Print the marker-delimited PHP block for a single bridge, including
# surrounding BEGIN/END markers, indented to match the scaffold's filter
# body. Strings are escaped for PHP single-quoted literals (backslash, single
# quote); args_json is emitted verbatim because it is a literal JSON array
# the caller has already constructed.
_cli_channel_render_block() {
  local name="$1" command="$2" args_json="$3" detach="$4" timeout="$5"
  local esc_name esc_command esc_args
  esc_name=$(_cli_channel_php_escape "$name")
  esc_command=$(_cli_channel_php_escape "$command")
  # Convert JSON array to PHP array literal: [...] is valid in both. Single
  # quotes inside the JSON would be a problem; the caller is responsible for
  # passing JSON with double-quoted strings, which we rewrite to single-quoted
  # PHP strings via sed (no embedded quotes expected in real argv tokens).
  esc_args=$(_cli_channel_json_to_php_array "$args_json")

  cat <<PHP
    // BEGIN bridge:${esc_name}
    \$channels['${esc_name}'] = [
        'command' => '${esc_command}',
        'args'    => ${esc_args},
        'detach'  => ${detach},
        'timeout' => ${timeout},
    ];
    // END bridge:${esc_name}
PHP
}

# _cli_channel_php_escape <string>
#
# Escape a string for inclusion inside a PHP single-quoted literal. PHP
# single-quoted strings only require escaping `\` and `'`.
_cli_channel_php_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf '%s' "$s"
}

# _cli_channel_json_to_php_array <json_array_literal>
#
# Convert a JSON array of strings like ["send","--channel","{recipient}"] into
# a PHP array literal [ 'send', '--channel', '{recipient}' ]. Uses python3 if
# available (handles edge cases properly); falls back to a sed transform for
# the simple case (no embedded quotes, no nested arrays) which is all we ship.
_cli_channel_json_to_php_array() {
  local json="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json" <<'PY'
import json, sys
arr = json.loads(sys.argv[1])
def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")
parts = ", ".join("'" + esc(x) + "'" for x in arr)
print("[ " + parts + " ]")
PY
    return $?
  fi
  # Fallback: naive substitution. Works for our argv vocabulary (no embedded
  # single quotes, no escapes) — every bridge argv template ships as plain
  # ASCII flags and substitution tokens.
  local out="$json"
  out="${out//\"/\'}"
  out="${out//,/, }"
  out="${out//\[/[ }"
  out="${out//\]/ ]}"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Register / unregister
# ---------------------------------------------------------------------------

# cli_channel_register <name> <command> <args_json> [detach] [timeout]
#
# Upsert <name>'s block in the mu-plugin file. Idempotent: re-running with the
# same arguments leaves the file unchanged; re-running with different
# arguments replaces just <name>'s block. Other bridges' blocks are preserved.
#
# Defaults:
#   detach   — "true"  (CLI bridges dispatch fire-and-forget by default)
#   timeout  — "600"   (10 minutes; matches DMC's default per #412)
cli_channel_register() {
  local name="$1" command="$2" args_json="$3"
  local detach="${4:-true}"
  local timeout="${5:-600}"

  if [ -z "$name" ] || [ -z "$command" ] || [ -z "$args_json" ]; then
    warn "  cli_channel_register: missing required args (name=$name command=$command args=$args_json)"
    return 1
  fi

  local file
  file="$(cli_channel_mu_plugin_path)" || {
    warn "  cli_channel_register: SITE_PATH not set — skipping channel '$name'"
    return 1
  }

  cli_channel_ensure_mu_plugin_file || return 1

  local new_block
  new_block=$(_cli_channel_render_block "$name" "$command" "$args_json" "$detach" "$timeout")

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would register CLI channel '$name' in $file"
    echo -e "${BLUE}[dry-run]${NC} Block:"
    echo "$new_block" | sed 's/^/    /'
    return 0
  fi

  # Read current file, check if the bridge's block already matches.
  if _cli_channel_block_matches "$file" "$name" "$new_block"; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _cli_channel_rewrite "$file" "$name" "$new_block" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  # Self-heal legacy 0600 files written before the umask fix in #133.
  # mktemp creates with mode 0600 so mv preserves that — force 0644.
  chmod 0644 "$file"
  log "  Registered CLI channel '$name' in $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("CLI channel: $name")
  fi
}

# cli_channel_unregister <name>
#
# Remove <name>'s block from the mu-plugin file. No-op if the file does not
# exist, or if the block is not present. Other bridges' blocks are preserved.
cli_channel_unregister() {
  local name="$1"
  if [ -z "$name" ]; then
    warn "  cli_channel_unregister: missing name"
    return 1
  fi

  local file
  file="$(cli_channel_mu_plugin_path)" || {
    return 0
  }
  [ -f "$file" ] || return 0

  if ! grep -q "// BEGIN bridge:${name}\$" "$file"; then
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would unregister CLI channel '$name' from $file"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _cli_channel_rewrite "$file" "$name" "" > "$tmp"
  mv "$tmp" "$file"
  chmod 0644 "$file"
  log "  Unregistered CLI channel '$name' from $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("CLI channel removed: $name")
  fi
}

# _cli_channel_block_matches <file> <name> <new_block>
#
# Return 0 if the existing block for <name> in <file> already equals
# <new_block> verbatim; otherwise 1. Used to short-circuit no-op rewrites.
_cli_channel_block_matches() {
  local file="$1" name="$2" new_block="$3"
  local existing
  existing=$(awk -v name="$name" '
    $0 == "    // BEGIN bridge:" name { capturing=1 }
    capturing { print }
    $0 == "    // END bridge:" name { exit }
  ' "$file")
  [ "$existing" = "$new_block" ]
}

# _cli_channel_rewrite <file> <name> <new_block>
#
# Stream <file> to stdout, replacing the existing block for <name> with
# <new_block>, or inserting <new_block> immediately before the
# `// END bridges` marker if no block for <name> exists yet. Empty
# <new_block> removes the bridge's block entirely (used by unregister).
_cli_channel_rewrite() {
  local file="$1" name="$2" new_block="$3"
  awk -v name="$name" -v new_block="$new_block" '
    BEGIN {
      begin_marker = "    // BEGIN bridge:" name
      end_marker   = "    // END bridge:" name
      inserted = 0
      skipping = 0
    }
    {
      if ($0 == begin_marker) {
        skipping = 1
        if (new_block != "") {
          print new_block
          inserted = 1
        }
        next
      }
      if (skipping) {
        if ($0 == end_marker) {
          skipping = 0
        }
        next
      }
      if (!inserted && $0 == "    // END bridges") {
        if (new_block != "") {
          print new_block
          inserted = 1
        }
      }
      print
    }
  ' "$file"
}
