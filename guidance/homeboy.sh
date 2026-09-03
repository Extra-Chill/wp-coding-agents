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

# Quoted heredoc ('PHP_BLOCK') so PHP $variables, backticks, and ${...} are
# emitted verbatim — bash never touches them.
_guidance_homeboy_live_block() {
  cat <<'PHP_BLOCK'
    // BEGIN agents-md-guidance:homeboy-cli
    if ( ! function_exists( 'wp_coding_agents_homeboy_binary' ) ) {
        function wp_coding_agents_homeboy_binary() {
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
            return $homeboy;
        }
    }

    if ( ! function_exists( 'wp_coding_agents_render_homeboy_cli_section' ) ) {
        function wp_coding_agents_render_homeboy_cli_section() {
            if ( wp_coding_agents_homeboy_binary() === null ) {
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
    if ( wp_coding_agents_homeboy_binary() !== null ) {
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
