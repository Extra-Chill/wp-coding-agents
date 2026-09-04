#!/bin/bash
# guidance/homeboy.sh — Homeboy orchestration routing guidance (issues #208, #254, #298).
#
# Strictly presence-gated on the optional homeboy binary, and additionally on
# modes that actually have a workspace: the routing advice below is about
# cooking tracked changes in managed worktrees, which is meaningless on a
# managed-hosting install where the agent edits live source and never touches
# git.
#
# The section is registered as a LIVE block: the PHP callback re-checks for the
# binary at AGENTS.md compose time, so a host that loses homeboy stops emitting
# the section without needing a wp-coding-agents sync (the #254 trigger gap).
# Nothing about homeboy is baked at setup time.
#
# This unit implements guidance_register rather than guidance_render because its
# payload is a hand-written PHP block, not static markdown.

guidance_id() { printf 'homeboy-cli'; }
guidance_priority() { printf '30'; }
guidance_label() { printf 'Homeboy'; }
guidance_description() { printf 'Host orchestration routing, safety, and discovery guidance.'; }
guidance_freshness() { printf 'live'; }

guidance_applies() {
  if ! source_policy_workspace_enabled; then
    return 1
  fi

  local homeboy_path
  homeboy_path="$(type -P homeboy 2>/dev/null || true)"
  [ -n "$homeboy_path" ] && [ -f "$homeboy_path" ] && [ -x "$homeboy_path" ]
}

guidance_register() {
  local file
  file="$(agents_md_guidance_mu_plugin_path)" || {
    warn "  guidance/homeboy: SITE_PATH not set — skipping"
    return 1
  }

  agents_md_guidance_ensure_mu_plugin_file || return 1

  local new_block
  new_block="$(_guidance_homeboy_live_block)" || {
    warn "  guidance/homeboy: could not render live block — skipping"
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

# _guidance_homeboy_php_quote <value>
#
# Escape a filesystem path for embedding in a PHP single-quoted string
# literal. Only backslash and single-quote are special inside '...'.
_guidance_homeboy_php_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf '%s' "$value"
}

# Emit the live PHP block with the resolved homeboy path baked in.
#
# The binary is resolved ONCE here, at sync time, using the same `type -P`
# lookup as guidance_applies(). The emitted PHP checks that one absolute
# path instead of walking getenv('PATH') at compose time.
#
# This matters because AGENTS.md is recomposed by whatever process happens
# to trigger it — PHP-FPM, cron, a plugin upgrade, a WP-CLI call with a
# trimmed environment. Those do not inherit an interactive PATH, so a
# PATH-based probe reported "homeboy absent" on a host where homeboy was
# installed and executable, and the section silently deleted itself (#575).
#
# The #254 live gate is preserved: the emitted code still re-checks
# is_executable() at every compose, so a host that loses the binary stops
# emitting the section with no wp-coding-agents sync.
#
# Quoted heredoc ('PHP_BLOCK') so PHP $variables, backticks, and ${...} are
# emitted verbatim — bash never touches them. The single baked value is
# substituted afterward via a placeholder, preserving that property.
_guidance_homeboy_live_block() {
  local homeboy_path
  homeboy_path="$(type -P homeboy 2>/dev/null || true)"
  if [ -z "$homeboy_path" ]; then
    return 1
  fi

  local quoted_path
  quoted_path="$(_guidance_homeboy_php_quote "$homeboy_path")"

  cat <<'PHP_BLOCK' | sed "s|__WP_CODING_AGENTS_HOMEBOY_BIN__|${quoted_path//|/\\|}|g"
    // BEGIN agents-md-guidance:homeboy-cli
    // Absolute path resolved by wp-coding-agents at sync time. Checked live
    // at every compose so losing the binary drops the section (#254), but
    // never re-derived from the composing process's PATH (#575).
    if ( ! defined( 'WP_CODING_AGENTS_HOMEBOY_BIN' ) ) {
        define( 'WP_CODING_AGENTS_HOMEBOY_BIN', '__WP_CODING_AGENTS_HOMEBOY_BIN__' );
    }

    if ( ! function_exists( 'wp_coding_agents_homeboy_available' ) ) {
        function wp_coding_agents_homeboy_available() {
            return @is_executable( WP_CODING_AGENTS_HOMEBOY_BIN );
        }
    }

    if ( ! function_exists( 'wp_coding_agents_render_homeboy_cli_section' ) ) {
        function wp_coding_agents_render_homeboy_cli_section() {
            if ( ! wp_coding_agents_homeboy_available() ) {
                return '';
            }

            return <<<'MD'
## Homeboy

Homeboy orchestrates coding agents, deterministic gates, evidence, promotion, review, releases, and deployments. Homeboy owns the native Rust worktree lifecycle and Cook.

**Default routing**
- One tracked change: `homeboy agent-task cook`
- Multiple independent changes: `homeboy agent-task fanout cook-batch`
- Review a candidate: `homeboy review`
- Inspect runs and evidence: `homeboy runs`
- Repeating workflows: `homeboy agent-task loop`; explicitly stateful workflows: `homeboy agent-task controller`
- Component and runner health: `homeboy status` and `homeboy runner status`

**Operator boundary**
Run `homeboy release` or `homeboy deploy` only when the user explicitly asks.

**Control-plane recovery**
Homeboy remains the normal owner of tracked coding work. When Cook cannot admit or run a task:
1. Validate the selected route with `homeboy agent-task cook --preview` using the task's repository, tracker URL, and verification gates.
2. Check `homeboy agent-task providers`, `homeboy status`, and `homeboy runner status`. Use `homeboy agent-task cook --help-full` for the exact configured alternative-route syntax; do not guess provider or runner flags.
3. Recover an unavailable runner or control-plane service through its documented Homeboy operation, then retry Cook within its configured attempt and provider-rotation budget.
4. After that bounded recovery fails, stop and request explicit operator authorization before invoking a coding runtime directly.

An authorized direct fallback is an exception, not a replacement for Homeboy. Work in an isolated Git worktree linked to the tracker; run and record deterministic verification; then follow the normal commit, push, review, pull-request, and AI-disclosure policy. Record that finalization occurred outside Homeboy and retain the direct runtime command plus session or run evidence with the tracker.

**Discovery**
Use `homeboy --help` and `homeboy <command> --help` for the live command contract. Inspect active configuration with `homeboy config show` and provider readiness with `homeboy agent-task providers`.

MD;
        }
    }

    // Gate registration itself at composition time.
    if ( wp_coding_agents_homeboy_available() ) {
        \DataMachine\Engine\AI\SectionRegistry::register(
            'AGENTS.md',
            'homeboy-cli',
            30,
            static function () {
                return wp_coding_agents_render_homeboy_cli_section();
            },
            array(
                'label'       => 'Homeboy',
                'description' => 'Host orchestration routing, safety, and discovery guidance.',
                'owner'       => 'wp-coding-agents',
                'freshness'   => 'live',
                'conditions'  => 'Registered only while the homeboy binary is executable at AGENTS.md compose time.',
            )
        );

    }
    // END agents-md-guidance:homeboy-cli
PHP_BLOCK
}
