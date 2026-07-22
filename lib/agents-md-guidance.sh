#!/bin/bash
# lib/agents-md-guidance.sh — AGENTS.md SectionRegistry guidance writer.
#
# wp-coding-agents owns integration-specific runtime guidance for the tools it
# installs and wires together. Data Machine Code owns the generic AGENTS.md
# composition substrate; this helper publishes wp-coding-agents' integration
# guidance into that substrate through Data Machine's SectionRegistry without
# making DMC know about Homeboy, Kimaki, OpenCode, or WP Codebox conventions.
#
# Resolved file: $SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agents-md.php
#
# Public surface:
#   agents_md_guidance_mu_plugin_path
#   agents_md_guidance_ensure_mu_plugin_file
#   agents_md_guidance_register <section_id> <priority> <label> <description> <content>
#   agents_md_guidance_unregister <section_id>
#   agents_md_guidance_sync_homeboy_cli          # presence-gated on `command -v homeboy`
#   agents_md_guidance_register_homeboy_cli      # writes a LIVE-enumeration PHP block
#   agents_md_guidance_unregister_homeboy_cli
#
# The homeboy-cli section is generated LIVE at AGENTS.md compose time: the
# mu-plugin callback shells out to `homeboy --help` on every compose (cached
# briefly on the binary mtime + version), so a `homeboy upgrade` converges on
# the next compose without requiring a wp-coding-agents sync. See issue #254.
#
# Honors DRY_RUN (logs intent, makes no changes).

agents_md_guidance_mu_plugin_path() {
  if [ -z "${SITE_PATH:-}" ]; then
    return 1
  fi
  printf '%s' "$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-agents-md.php"
}

agents_md_guidance_ensure_mu_plugin_file() {
  local file
  file="$(agents_md_guidance_mu_plugin_path)" || {
    warn "  agents_md_guidance_ensure_mu_plugin_file: SITE_PATH not set — skipping"
    return 1
  }

  if [ -f "$file" ]; then
    return 0
  fi

  local dir="${file%/*}"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mkdir -p $dir"
    echo -e "${BLUE}[dry-run]${NC} Would write AGENTS.md guidance mu-plugin to $file"
    return 0
  fi

  mkdir -p "$dir"
  cat > "$file" <<'PHP'
<?php
/**
 * Plugin Name: wp-coding-agents — AGENTS.md guidance registry
 * Description: Registers wp-coding-agents-owned integration guidance as
 *              composable AGENTS.md sections through Data Machine's
 *              SectionRegistry. Managed by wp-coding-agents setup/upgrade —
 *              do not edit by hand.
 *
 * Each integration contributes a marker-delimited PHP block of the form:
 *
 *   // BEGIN agents-md-guidance:<section_id>
 *   \DataMachine\Engine\AI\SectionRegistry::register( ... );
 *   // END agents-md-guidance:<section_id>
 *
 * @package wp-coding-agents
 */

defined( 'ABSPATH' ) || exit;

add_action( 'datamachine_sections', function () {
    if ( ! function_exists( 'datamachine_agents_md_enabled' ) || ! datamachine_agents_md_enabled() ) {
        return;
    }

    if ( ! class_exists( '\DataMachine\Engine\AI\SectionRegistry' ) ) {
        return;
    }

    // BEGIN agents-md-guidance-sections
    // END agents-md-guidance-sections
} );
PHP

  service_file_normalize_perms "$file"
  log "  Wrote AGENTS.md guidance mu-plugin scaffold: $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("created $file")
  fi
}

agents_md_guidance_register() {
  local section_id="$1" priority="$2" label="$3" description="$4" content="$5"

  if [ -z "$section_id" ] || [ -z "$priority" ] || [ -z "$label" ] || [ -z "$content" ]; then
    warn "  agents_md_guidance_register: missing required args (section_id=$section_id priority=$priority label=$label)"
    return 1
  fi

  _agents_md_guidance_validate_section_id "$section_id" || return 1
  _agents_md_guidance_validate_priority "$priority" || return 1

  local file
  file="$(agents_md_guidance_mu_plugin_path)" || {
    warn "  agents_md_guidance_register: SITE_PATH not set — skipping section '$section_id'"
    return 1
  }

  agents_md_guidance_ensure_mu_plugin_file || return 1

  local new_block
  new_block=$(_agents_md_guidance_render_block "$section_id" "$priority" "$label" "$description" "$content")

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would register AGENTS.md guidance section '$section_id' in $file"
    echo -e "${BLUE}[dry-run]${NC} Block:"
    echo "$new_block" | sed 's/^/    /'
    return 0
  fi

  if _agents_md_guidance_block_matches "$file" "$section_id" "$new_block"; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _agents_md_guidance_rewrite "$file" "$section_id" "$new_block" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  service_file_normalize_perms "$file"
  log "  Registered AGENTS.md guidance section '$section_id' in $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance: $section_id")
  fi
}

agents_md_guidance_unregister() {
  local section_id="$1"
  if [ -z "$section_id" ]; then
    warn "  agents_md_guidance_unregister: missing section_id"
    return 1
  fi

  _agents_md_guidance_validate_section_id "$section_id" || return 1

  local file
  file="$(agents_md_guidance_mu_plugin_path)" || return 0
  [ -f "$file" ] || return 0

  if ! grep -q "// BEGIN agents-md-guidance:${section_id}\$" "$file"; then
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would unregister AGENTS.md guidance section '$section_id' from $file"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _agents_md_guidance_rewrite "$file" "$section_id" "" > "$tmp"
  mv "$tmp" "$file"
  service_file_normalize_perms "$file"
  log "  Unregistered AGENTS.md guidance section '$section_id' from $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance removed: $section_id")
  fi
}

# ---------------------------------------------------------------------------
# Homeboy CLI command map (issues #208, #254)
#
# homeboy is an OPTIONAL host binary. The map is strictly presence-gated:
#   - present (`command -v homeboy` succeeds) -> emit a first-class section
#     whose callback ENUMERATES `homeboy --help` LIVE at AGENTS.md compose
#     time. A `homeboy upgrade` therefore converges on the next compose,
#     with no wp-coding-agents sync required (the #254 trigger gap).
#   - absent -> complete no-op (unregister any stale section, emit nothing).
#
# The command list is NEVER baked into the mu-plugin as a frozen string;
# the previous static-bake design was the #254 defect. The PHP helper that
# performs the live enumeration is shipped inline in the homeboy-cli
# section block (see _agents_md_guidance_render_homeboy_live_block), with
# a WP transient cache keyed on the homeboy binary path + mtime + version
# so steady-state compiles are free and the cache self-heals on upgrade.
# ---------------------------------------------------------------------------

# agents_md_guidance_sync_homeboy_cli
#
# Presence-gated entry point. Reuses the same `command -v homeboy` detection
# the rest of the homeboy integration uses so the section and the integration
# agree on presence. When homeboy is present, registers a LIVE-enumeration
# section block (no content is baked at setup time).
agents_md_guidance_sync_homeboy_cli() {
  if command -v homeboy >/dev/null 2>&1; then
    agents_md_guidance_register_homeboy_cli
  else
    agents_md_guidance_unregister_homeboy_cli
  fi
}

# agents_md_guidance_register_homeboy_cli
#
# Writes a self-contained PHP block whose SectionRegistry callback shells
# out to `homeboy --help` at compose time and parses the Commands: block in
# PHP. The block is marker-delimited (BEGIN/END agents-md-guidance:homeboy-cli)
# so it is idempotent and removable by the standard unregister path.
#
# No homeboy output is captured at setup time — that was the #254 bug. The
# callback is the only thing that touches homeboy, and it runs on every
# `wp datamachine memory compose AGENTS.md`.
agents_md_guidance_register_homeboy_cli() {
  local file
  file="$(agents_md_guidance_mu_plugin_path)" || {
    warn "  agents_md_guidance_register_homeboy_cli: SITE_PATH not set — skipping"
    return 1
  }

  agents_md_guidance_ensure_mu_plugin_file || return 1

  local new_block
  new_block="$(_agents_md_guidance_render_homeboy_live_block)" || {
    warn "  agents_md_guidance_register_homeboy_cli: could not render live block — skipping"
    return 1
  }

  agents_md_guidance_ensure_mu_plugin_file || return 1

  local new_block
  new_block="$(_agents_md_guidance_render_homeboy_live_block)" || {
    warn "  agents_md_guidance_register_homeboy_cli: could not render live block — skipping"
    return 1
  }

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would register live AGENTS.md guidance section 'homeboy-cli' in $file"
    echo -e "${BLUE}[dry-run]${NC} Block:"
    echo "$new_block" | sed 's/^/    /'
    return 0
  fi

  if _agents_md_guidance_block_matches "$file" "homeboy-cli" "$new_block"; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  _agents_md_guidance_rewrite "$file" "homeboy-cli" "$new_block" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  service_file_normalize_perms "$file"
  log "  Registered live AGENTS.md guidance section 'homeboy-cli' in $file"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("AGENTS.md guidance: homeboy-cli (live)")
  fi
}

agents_md_guidance_unregister_homeboy_cli() {
  agents_md_guidance_unregister "homeboy-cli"
}

# _agents_md_guidance_render_homeboy_live_block
#
# Emits the PHP for the homeboy-cli section block. The block is
# self-contained: it defines two helper functions (guarded by
# `function_exists` so re-firing the datamachine_sections action does not
# fatally redeclare them) and then registers a SectionRegistry section
# whose callback invokes the live enumerator.
#
# The helpers:
#   wp_coding_agents_render_homeboy_cli_section()
#       Top-level orchestrator. Resolves `homeboy` on PATH, reads
#       `--version` and the binary mtime for the cache key, checks the WP
#       transient cache, shells out to `homeboy --help`, hands the help
#       text to the parser, caches the rendered markdown, and returns it.
#       Returns '' (section contributes nothing) when homeboy is absent,
#       shell_exec is unavailable, the binary fails, or the help text has
#       no parseable Commands: block.
#   wp_coding_agents_parse_homeboy_cli_help( $help )
#       Pure parser. Faithful PHP port of the original python parser:
#       recognizes the `Commands:` block, ends at blank line / Options:,
#       drops the `help`/`list` meta commands, renders the same markdown
#       shape (intro, optional "Common entrypoints", full list, footer).
#
# Quoted heredoc ('PHP_BLOCK') so PHP $variables, backticks, and ${...}
# are emitted verbatim — bash never touches them.
_agents_md_guidance_render_homeboy_live_block() {
  cat <<'PHP_BLOCK'
    // BEGIN agents-md-guidance:homeboy-cli
    if ( ! function_exists( 'wp_coding_agents_render_homeboy_cli_section' ) ) {
        function wp_coding_agents_render_homeboy_cli_section() {
            // Homeboy is optional. The section is a clean no-op when the
            // binary is not on PATH, matching the presence-gating the bash
            // setup path applies.
            $homeboy = null;
            $path_env = ( is_callable( 'getenv' ) ) ? getenv( 'PATH' ) : false;
            if ( is_string( $path_env ) && $path_env !== '' ) {
                foreach ( explode( PATH_SEPARATOR, $path_env ) as $dir ) {
                    if ( $dir === '' ) {
                        continue;
                    }
                    $candidate = rtrim( $dir, '/' ) . '/homeboy';
                    if ( @is_executable( $candidate ) ) {
                        $homeboy = $candidate;
                        break;
                    }
                }
            }
            if ( $homeboy === null ) {
                return '';
            }

            // shell_exec is the safe argv form here (hard-coded `homeboy`
            // subcommands, no user input). It can be disabled in php.ini —
            // in that case we degrade to a no-op rather than emit a broken
            // section.
            if ( ! is_callable( 'shell_exec' ) ) {
                return '';
            }

            // Cache key on path + mtime + version. A `homeboy upgrade`
            // changes both mtime and version output, so the key flips and
            // the next compose re-enumerates. Short TTL is just a safety
            // net for the unlikely case where the binary changes without
            // either signal moving.
            $version_out = @shell_exec( escapeshellarg( $homeboy ) . ' --version 2>/dev/null' );
            $version     = ( is_string( $version_out ) ) ? trim( $version_out ) : '';
            $mtime       = @filemtime( $homeboy );
            $cache_key   = 'wca_homeboy_cli_agents_md_' . md5( $homeboy . '|' . $version . '|' . ( $mtime ?: '0' ) );

            if ( is_callable( 'get_transient' ) ) {
                $cached = get_transient( $cache_key );
                if ( is_string( $cached ) && $cached !== '' ) {
                    return $cached;
                }
            }

            $help = @shell_exec( escapeshellarg( $homeboy ) . ' --help 2>/dev/null' );
            if ( ! is_string( $help ) || $help === '' ) {
                return '';
            }

            $content = wp_coding_agents_parse_homeboy_cli_help( $help );
            if ( $content === '' ) {
                return '';
            }

            if ( is_callable( 'set_transient' ) ) {
                set_transient( $cache_key, $content, 3600 );
            }

            return $content;
        }
    }

    if ( ! function_exists( 'wp_coding_agents_parse_homeboy_cli_help' ) ) {
        function wp_coding_agents_parse_homeboy_cli_help( $help ) {
            // Faithful PHP port of the original python parser. See
            // lib/agents-md-guidance.sh history.
            $commands = array();
            $in_commands = false;
            foreach ( preg_split( '/\r\n|\r|\n/', (string) $help ) as $raw ) {
                $stripped = trim( $raw );
                if ( ! $in_commands ) {
                    if ( $stripped === 'Commands:' ) {
                        $in_commands = true;
                    }
                    continue;
                }

                // The commands block ends at the first blank line or the
                // Options: header.
                if ( $stripped === '' || $stripped === 'Options:' || strpos( $raw, 'Options:' ) === 0 ) {
                    break;
                }

                if ( ! preg_match( '/^\s+([A-Za-z0-9][A-Za-z0-9_-]*)\s{2,}(.+?)\s*$/', $raw, $matches ) ) {
                    // Continuation / wrapped summary lines have no command
                    // token; ignore them.
                    continue;
                }

                $commands[] = array( $matches[1], trim( $matches[2] ) );
            }

            if ( ! $commands ) {
                return '';
            }

            // `help` / `list` are meta commands; drop them from the map.
            // The footer already tells the agent how to discover
            // everything.
            $skip = array( 'help' => true, 'list' => true );
            $commands = array_values(
                array_filter(
                    $commands,
                    static function ( $c ) use ( $skip ) {
                        return ! isset( $skip[ $c[0] ] );
                    }
                )
            );

            if ( ! $commands ) {
                return '';
            }

            $summaries = array();
            foreach ( $commands as $c ) {
                $summaries[ $c[0] ] = $c[1];
            }

            $common_order = array(
                'status',
                'triage',
                'worktree',
                'review',
                'build',
                'test',
                'agent-task',
                'runs',
            );

            $lines = array();
            $lines[] = 'Homeboy is the host orchestrator binary — build, deploy, release, triage, test, and inspect components from the CLI. The command map below is generated live from `homeboy --help` at AGENTS.md compose time, so it always reflects the currently-installed homeboy binary.';

            $common_entrypoints = array();
            foreach ( $common_order as $name ) {
                if ( isset( $summaries[ $name ] ) ) {
                    $common_entrypoints[] = $name;
                }
            }
            if ( $common_entrypoints ) {
                $lines[] = '';
                $lines[] = 'Common entrypoints:';
                foreach ( $common_entrypoints as $name ) {
                    $lines[] = '- `homeboy ' . $name . '` — ' . $summaries[ $name ];
                }
            }

            $lines[] = '';
            foreach ( $commands as $c ) {
                $lines[] = '- `homeboy ' . $c[0] . '` — ' . $c[1];
            }

            $lines[] = '';
            $lines[] = 'For agent work, use `homeboy agent-task cook` for one issue or reviewable PR, `homeboy agent-task fanout cook-batch` for multiple independent issues, `homeboy agent-task loop` for a named repeating workflow, and `homeboy agent-task controller` for workflows with explicit actions, events, waits, or policy state.';
            $lines[] = 'Inspect live configuration with `homeboy config show`. Discover current agent-task providers with `homeboy agent-task providers`.';
            $lines[] = 'Discover everything: `homeboy --help`. Drill into a command with `homeboy <command> --help`, including `homeboy config --help` and `homeboy agent-task --help`. Releases (`homeboy release`) and deploys (`homeboy deploy`) are operator actions — run them only when the user explicitly asks.';

            return implode( "\n", $lines );
        }
    }

    \DataMachine\Engine\AI\SectionRegistry::register(
        'AGENTS.md',
        'homeboy-cli',
        34,
        static function () {
            return wp_coding_agents_render_homeboy_cli_section();
        },
        array(
            'label'       => 'Homeboy CLI',
            'description' => 'Host orchestrator command map, enumerated live from \'homeboy --help\' at AGENTS.md compose time.',
            'owner'       => 'wp-coding-agents',
            'freshness'   => 'live',
            'conditions'  => 'Generated live from \'homeboy --help\' at AGENTS.md compose time on hosts where the homeboy binary is installed; removed when homeboy is absent. Cached briefly via WP transient keyed on the homeboy binary mtime and version, so a `homeboy upgrade` converges on the next compose without a wp-coding-agents sync.',
        )
    );
    // END agents-md-guidance:homeboy-cli
PHP_BLOCK
}

_agents_md_guidance_render_block() {
  local section_id="$1" priority="$2" label="$3" description="$4" content="$5"
  AGENTS_MD_GUIDANCE_SECTION_ID="$section_id" \
  AGENTS_MD_GUIDANCE_PRIORITY="$priority" \
  AGENTS_MD_GUIDANCE_LABEL="$label" \
  AGENTS_MD_GUIDANCE_DESCRIPTION="$description" \
  AGENTS_MD_GUIDANCE_CONTENT="$content" \
  AGENTS_MD_GUIDANCE_FRESHNESS="${AGENTS_MD_GUIDANCE_FRESHNESS:-conditional}" \
  AGENTS_MD_GUIDANCE_CONDITIONS="${AGENTS_MD_GUIDANCE_CONDITIONS:-Registered by wp-coding-agents when the integration is available; removed when unavailable.}" \
  python3 <<'PY'
import os
import re
import sys

section_id = os.environ["AGENTS_MD_GUIDANCE_SECTION_ID"]
priority = os.environ["AGENTS_MD_GUIDANCE_PRIORITY"]
label = os.environ["AGENTS_MD_GUIDANCE_LABEL"]
description = os.environ.get("AGENTS_MD_GUIDANCE_DESCRIPTION", "")
content = os.environ["AGENTS_MD_GUIDANCE_CONTENT"].rstrip("\n")
freshness = os.environ.get("AGENTS_MD_GUIDANCE_FRESHNESS", "conditional")
conditions = os.environ.get("AGENTS_MD_GUIDANCE_CONDITIONS", "")

if not re.fullmatch(r"[A-Za-z0-9_.-]+", section_id):
    sys.stderr.write("AGENTS.md guidance section id may only contain letters, numbers, dots, underscores, and hyphens\n")
    sys.exit(1)
try:
    priority_int = int(priority)
except ValueError:
    sys.stderr.write("AGENTS.md guidance priority must be an integer\n")
    sys.exit(1)

def esc(value):
    return value.replace("\\", "\\\\").replace("'", "\\'")

print(f"    // BEGIN agents-md-guidance:{section_id}")
print("    \\DataMachine\\Engine\\AI\\SectionRegistry::register(")
print("        'AGENTS.md',")
print(f"        '{esc(section_id)}',")
print(f"        {priority_int},")
print("        static function () {")
print("            return <<<'MD'")
print(content)
print("MD;")
print("        },")
print("        array(")
print(f"            'label'       => '{esc(label)}',")
print(f"            'description' => '{esc(description)}',")
print("            'owner'       => 'wp-coding-agents',")
print(f"            'freshness'   => '{esc(freshness)}',")
print(f"            'conditions'  => '{esc(conditions)}',")
print("        )")
print("    );")
print(f"    // END agents-md-guidance:{section_id}")
PY
}

_agents_md_guidance_validate_section_id() {
  local section_id="$1"
  if printf '%s' "$section_id" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
    return 0
  fi

  warn "  AGENTS.md guidance section id may only contain letters, numbers, dots, underscores, and hyphens: $section_id"
  return 1
}

_agents_md_guidance_validate_priority() {
  local priority="$1"
  if printf '%s' "$priority" | grep -Eq '^-?[0-9]+$'; then
    return 0
  fi

  warn "  AGENTS.md guidance priority must be an integer: $priority"
  return 1
}

_agents_md_guidance_block_matches() {
  local file="$1" section_id="$2" new_block="$3"
  local existing
  existing=$(awk -v sid="$section_id" '
    $0 == "    // BEGIN agents-md-guidance:" sid { capturing=1 }
    capturing { print }
    $0 == "    // END agents-md-guidance:" sid { exit }
  ' "$file")
  [ "$existing" = "$new_block" ]
}

_agents_md_guidance_rewrite() {
  local file="$1" section_id="$2" new_block="$3"
  AGENTS_MD_GUIDANCE_NEW_BLOCK="$new_block" python3 - "$file" "$section_id" <<'PY'
import os
import sys

file_path, section_id = sys.argv[1], sys.argv[2]
new_block = os.environ.get("AGENTS_MD_GUIDANCE_NEW_BLOCK", "")
begin_marker = f"    // BEGIN agents-md-guidance:{section_id}"
end_marker = f"    // END agents-md-guidance:{section_id}"

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

    if not inserted and line == "    // END agents-md-guidance-sections":
        if new_block:
            out.extend(new_block.splitlines())
            inserted = True

    out.append(line)

sys.stdout.write("\n".join(out))
sys.stdout.write("\n")
PY
}
