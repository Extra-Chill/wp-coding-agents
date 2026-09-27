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

# ---------------------------------------------------------------------------
# Binary resolution (#633).
#
# #575/#577 bake an absolute homeboy path into the mu-plugin at sync time so
# AGENTS.md compose does not re-derive it from the composing process's PATH.
# That baked path also has to be executable by whichever identity actually
# composes AGENTS.md — typically the web server user (www-data on a standard
# nginx/PHP-FPM provision; see lib/wordpress.sh fix_ownership and
# harden_wp_config_permissions). The original `type -P homeboy` probe only
# proves the binary is on the SYNCING user's PATH, which can resolve to a
# per-user copy (e.g. ~/.local/bin/homeboy) whose parent directories are
# 0700/0750 and therefore unreachable by that other identity — the gate then
# silently drops the section with no visible signal (#633).

# _guidance_homeboy_managed_bin_path — the managed system install location.
# Overridable so tests never touch the real path, and so a host whose
# homeboy-upgrade helper installs somewhere else can still be recognized.
_guidance_homeboy_managed_bin_path() {
  printf '%s' "${WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN:-/usr/local/bin/homeboy}"
}

# _guidance_homeboy_bin_candidates — ordered, de-duplicated candidate paths.
#
#   1. WP_CODING_AGENTS_HOMEBOY_BIN — explicit sync-time override, for an
#      operator with a nonstandard install.
#   2. The managed system install location (see above): root-owned and
#      world-executable by convention, stable across every identity on the
#      box, unlike a per-user PATH entry.
#   3. `type -P homeboy` — the syncing user's PATH (the original #575
#      probe), kept as a last resort for hosts that run homeboy from
#      somewhere else but still keep it web-reachable.
#
# None of these are re-derived from the COMPOSING process's PATH — only from
# state fixed at sync time — which is the property #575 depends on.
_guidance_homeboy_bin_candidates() {
  local candidate seen=""
  for candidate in \
    "${WP_CODING_AGENTS_HOMEBOY_BIN:-}" \
    "$(_guidance_homeboy_managed_bin_path)" \
    "$(type -P homeboy 2>/dev/null || true)"
  do
    [ -n "$candidate" ] || continue
    case "$seen" in *"|$candidate|"*) continue ;; esac
    seen="$seen|$candidate|"
    printf '%s\n' "$candidate"
  done
}

# _guidance_homeboy_compose_user / _guidance_homeboy_compose_group — the
# identity AGENTS.md composes as. Derived from SITE_PATH's own owner/group
# (the identity lib/wordpress.sh's fix_ownership and
# harden_wp_config_permissions already establish for the web tree) rather
# than assumed to be "www-data" — a host with a different web user/group is
# still handled correctly. An explicit override wins when set.
_guidance_homeboy_compose_user() {
  if [ -n "${WP_CODING_AGENTS_COMPOSE_USER:-}" ]; then
    printf '%s' "$WP_CODING_AGENTS_COMPOSE_USER"
    return 0
  fi
  [ -n "${SITE_PATH:-}" ] && [ -e "$SITE_PATH" ] || return 1
  file_owner "$SITE_PATH" 2>/dev/null
}

_guidance_homeboy_compose_group() {
  if [ -n "${WP_CODING_AGENTS_COMPOSE_GROUP:-}" ]; then
    printf '%s' "$WP_CODING_AGENTS_COMPOSE_GROUP"
    return 0
  fi
  [ -n "${SITE_PATH:-}" ] && [ -e "$SITE_PATH" ] || return 1
  file_group "$SITE_PATH" 2>/dev/null
}

# _guidance_homeboy_mode_grants_exec <path> <user> <group>
#
# True if <path>'s permission bits grant execute/search to "other", to
# "group" when <path>'s owning group matches <group>, or to "owner" when
# <path>'s owner matches <user>. Works identically for files (execute) and
# directories (search) — both use the low bit of the relevant permission
# triad.
_guidance_homeboy_mode_grants_exec() {
  local path="$1" user="$2" group="$3" mode
  mode="$(file_mode "$path" 2>/dev/null)" || return 1
  [ "${#mode}" -ge 3 ] || return 1

  case "${mode: -1}" in 1|3|5|7) return 0 ;; esac

  if [ -n "$group" ] && [ "$(file_group "$path" 2>/dev/null || true)" = "$group" ]; then
    case "${mode: -2:1}" in 1|3|5|7) return 0 ;; esac
  fi

  if [ -n "$user" ] && [ "$(file_owner "$path" 2>/dev/null || true)" = "$user" ]; then
    case "${mode: -3:1}" in 1|3|5|7) return 0 ;; esac
  fi

  return 1
}

# _guidance_homeboy_world_reachable <path> <user> <group>
#
# True if every ancestor directory of <path>, and <path> itself, grants
# execute/search per _guidance_homeboy_mode_grants_exec. This is the
# permission-bit fallback used when a live sudo probe of the compose
# identity is not available — the common case, since sync does not usually
# run as root.
_guidance_homeboy_world_reachable() {
  local target="$1" user="$2" group="$3" dir
  dir="$(dirname -- "$target")"
  while :; do
    [ -d "$dir" ] || return 1
    _guidance_homeboy_mode_grants_exec "$dir" "$user" "$group" || return 1
    [ "$dir" = "/" ] && break
    dir="$(dirname -- "$dir")"
  done
  _guidance_homeboy_mode_grants_exec "$target" "$user" "$group"
}

# _guidance_homeboy_reachable_by_compose <path>
#
# True if <path> is a file the AGENTS.md compose identity can execute — not
# merely the syncing user (`type -P homeboy` alone only proves the latter,
# #633). Prefers a live `sudo -n -u <compose-user> test -x` probe when sync
# runs as root, mirroring homeboy_run()'s own drop-privilege gate in
# lib/homeboy.sh, where the probe is guaranteed not to hit a password
# prompt; otherwise falls back to the permission-bit walk above, which needs
# no privileged probe at all.
_guidance_homeboy_reachable_by_compose() {
  local path="$1"
  [ -n "$path" ] && [ -f "$path" ] && [ -x "$path" ] || return 1

  local compose_user
  compose_user="$(_guidance_homeboy_compose_user 2>/dev/null || true)"

  if [ -n "$compose_user" ] && [ "$(id -u)" -eq 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo -n -u "$compose_user" test -x "$path" 2>/dev/null
    return $?
  fi

  _guidance_homeboy_world_reachable "$path" "$compose_user" "$(_guidance_homeboy_compose_group 2>/dev/null || true)"
}

# _guidance_homeboy_resolve_bin — print the first candidate (see
# _guidance_homeboy_bin_candidates) that is both a homeboy binary and
# reachable by the compose identity. Exit non-zero when none qualify.
_guidance_homeboy_resolve_bin() {
  local candidate
  while IFS= read -r candidate; do
    if _guidance_homeboy_reachable_by_compose "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(_guidance_homeboy_bin_candidates)
  return 1
}

# _guidance_homeboy_warn_unreachable — called only once
# _guidance_homeboy_resolve_bin has failed. Silent when no candidate exists
# at all (homeboy is simply not installed — the normal, presence-gated
# opt-out, not a bug). Warns by name when at least one candidate exists and
# is executable for the syncing user but the compose identity cannot reach
# it — the exact #633 condition, previously dropped with no visible signal
# at all.
_guidance_homeboy_warn_unreachable() {
  local candidate found=false
  while IFS= read -r candidate; do
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    found=true
    warn "  guidance/homeboy: $candidate exists and is executable for the syncing user, but not for the AGENTS.md compose identity — the homeboy-cli guidance section will not compose. Move or symlink a managed binary somewhere world-executable (e.g. $(_guidance_homeboy_managed_bin_path)), or set WP_CODING_AGENTS_HOMEBOY_BIN to a path the compose identity can already reach."
  done < <(_guidance_homeboy_bin_candidates)
  [ "$found" = true ]
}

guidance_applies() {
  if ! source_policy_workspace_enabled; then
    return 1
  fi

  if [ -n "$(_guidance_homeboy_resolve_bin)" ]; then
    return 0
  fi

  _guidance_homeboy_warn_unreachable
  return 1
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
# The binary is resolved ONCE here, at sync time, using the same
# _guidance_homeboy_resolve_bin() candidate walk as guidance_applies() (#633).
# The emitted PHP checks that one absolute path instead of walking
# getenv('PATH') at compose time.
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
  homeboy_path="$(_guidance_homeboy_resolve_bin)"
  if [ -z "$homeboy_path" ]; then
    return 1
  fi

  local quoted_path
  quoted_path="$(_guidance_homeboy_php_quote "$homeboy_path")"

  local provenance producer_version producer_source
  provenance="$(agents_md_guidance_provenance_markdown)"
  producer_version="$(agents_md_guidance_producer_version)"
  producer_source="$(agents_md_guidance_producer_source)"
  cat <<'PHP_BLOCK' | sed \
    -e "s|__WP_CODING_AGENTS_HOMEBOY_BIN__|${quoted_path//|/\\|}|g" \
    -e "s|__WP_CODING_AGENTS_PROVENANCE__|${provenance//|/\\|}|g" \
    -e "s|__WP_CODING_AGENTS_PRODUCER_VERSION__|${producer_version//|/\\|}|g" \
    -e "s|__WP_CODING_AGENTS_PRODUCER_SOURCE__|${producer_source//|/\\|}|g"
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
__WP_CODING_AGENTS_PROVENANCE__
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
`homeboy release` and `homeboy deploy` run when the user asks.

**Control-plane recovery**
Homeboy remains the normal owner of tracked coding work. If Cook fails to admit a task:
1. Validate the selected route with `homeboy agent-task cook --preview` using the task's repository, tracker URL, and verification gates.
2. Check `homeboy agent-task providers`, `homeboy status`, and `homeboy runner status`. Use `homeboy agent-task cook --help-full` for the configured alternative-route syntax.
3. Recover the runner or control-plane through its documented Homeboy operation, then retry Cook within its configured attempt and provider-rotation budget.
4. After that budget is exhausted, request explicit operator authorization before invoking a coding runtime directly.

Authorized direct fallback stays exceptional. Work in an isolated Git worktree linked to the tracker; run and record deterministic verification; then follow commit, push, review, pull-request, and AI-disclosure policy. Record that finalization occurred outside Homeboy and keep the runtime command plus session evidence with the tracker.

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
                'producer_version' => '__WP_CODING_AGENTS_PRODUCER_VERSION__',
                'producer_source'  => '__WP_CODING_AGENTS_PRODUCER_SOURCE__',
                'freshness'   => 'live',
                'conditions'  => 'Registered only while the homeboy binary is executable at AGENTS.md compose time.',
            )
        );

    }
    // END agents-md-guidance:homeboy-cli
PHP_BLOCK
}
