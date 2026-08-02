#!/bin/bash
# lib/source-policy.sh — installed-WordPress-source policy, derived from posture.
#
# wp-coding-agents installs two fundamentally different kinds of agent:
#
#   engineering  The agent treats installed WordPress source as read-only
#                reference and makes every code change in a Data Machine Code
#                workspace, tracked in git and reviewed through GitHub. This is
#                the historical (and default) behavior.
#
#   managed      The agent edits the live theme and plugins in place at the
#                owner's request. There is no workspace, no git, and no GitHub
#                in the agent's world; changes are captured out-of-band (e.g.
#                `homeboy harvest` on a schedule) as restore points. Built for
#                managed agentic hosting, where a non-technical owner should
#                never have to deal with pull requests.
#
# That single choice has to be enforced in four unrelated places — three runtime
# permission surfaces and the generated AGENTS.md prose. Before this file the
# same three globs were hardcoded in all of them independently:
#
#   runtimes/opencode.sh        permission.edit
#   runtimes/claude-code.sh     permissions.deny
#   runtimes/codex.sh           permissions filesystem profile
#   lib/repair-opencode-json.py reconciliation of permission.edit
#   lib/agents-md-guidance.sh   the prose telling the agent what it may touch
#
# Duplicated policy drifts, and when the prose and the permissions disagree the
# agent is told to do something it is then blocked from doing. This module is
# the single answer all of them derive from, so posture cannot be half-applied.
#
# Public surface:
#   source_policy_resolve_posture          # sets POSTURE (flag -> recorded -> default)
#   source_policy_record_posture           # persists POSTURE for later upgrades
#   source_policy_is_valid <posture>
#   source_policy_read_only_roots          # newline-separated, ordered
#   source_policy_editable_roots           # newline-separated, ordered
#   source_policy_workspace_enabled        # 0 = workspace/git/GitHub apply
#
# Honors DRY_RUN (logs intent, makes no changes).

# The wp option wp-coding-agents records the chosen posture in. Mirrors the
# existing `datamachine_code_homeboy_available` pattern: a setup-time fact that
# upgrade.sh has to be able to rediscover without asking again.
SOURCE_POLICY_OPTION="wp_coding_agents_posture"
SOURCE_POLICY_DEFAULT_POSTURE="engineering"

# Every installed-source root wp-coding-agents has an opinion about, in the
# order they are emitted by every consumer. Adding a root here adds it to all
# runtimes and to the AGENTS.md prose at once.
_source_policy_all_roots() {
  printf '%s\n' \
    'wp-content/plugins' \
    'wp-content/themes' \
    'wp-includes'
}

source_policy_is_valid() {
  case "${1:-}" in
    engineering|managed) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve the active posture into the POSTURE global.
#
# Precedence: explicit --posture flag (POSTURE_EXPLICIT=true) > posture recorded
# on the install at setup time > engineering. The recorded value is what lets
# `upgrade.sh` converge a managed box without the operator repeating the flag —
# and, critically, without silently reverting it to engineering.
source_policy_resolve_posture() {
  if [ "${POSTURE_EXPLICIT:-false}" = true ]; then
    if ! source_policy_is_valid "${POSTURE:-}"; then
      error "Unknown --posture '${POSTURE:-}'. Supported: engineering, managed"
    fi
    log "Posture: $POSTURE (explicit)"
    return 0
  fi

  local recorded=""
  recorded="$(source_policy_recorded_posture)"

  if source_policy_is_valid "$recorded"; then
    POSTURE="$recorded"
    log "Posture: $POSTURE (recorded on this install)"
    return 0
  fi

  POSTURE="$SOURCE_POLICY_DEFAULT_POSTURE"
  log "Posture: $POSTURE (default)"
}

# Read the posture recorded on this install, or '' when unavailable.
#
# Deliberately quiet: a fresh install, a dry run, or a site whose database is
# not reachable yet must fall through to the default rather than fail.
source_policy_recorded_posture() {
  if [ "${DRY_RUN:-false}" = true ]; then
    printf '%s' "${POSTURE:-}"
    return 0
  fi

  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi

  wp_cmd option get "$SOURCE_POLICY_OPTION" 2>/dev/null | tr -d '[:space:]' || true
}

# Persist the resolved posture so upgrade.sh can rediscover it.
source_policy_record_posture() {
  local posture="${POSTURE:-$SOURCE_POLICY_DEFAULT_POSTURE}"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update $SOURCE_POLICY_OPTION $posture"
    return 0
  fi

  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi

  if [ "$(source_policy_recorded_posture)" = "$posture" ]; then
    return 0
  fi

  if wp_cmd option update "$SOURCE_POLICY_OPTION" "$posture" >/dev/null 2>&1; then
    log "  Recorded install posture: $posture"
    if [ -n "${UPDATED_ITEMS+x}" ]; then
      UPDATED_ITEMS+=("posture: $posture")
    fi
  else
    warn "Could not record install posture '$posture' — upgrades will fall back to $SOURCE_POLICY_DEFAULT_POSTURE"
  fi
}

# Roots the agent must NOT edit under the active posture.
#
# `wp-includes/` is WordPress core and is read-only in BOTH postures. Managed
# hosting hands the agent its own theme and plugins, never core.
source_policy_read_only_roots() {
  case "${POSTURE:-$SOURCE_POLICY_DEFAULT_POSTURE}" in
    managed)
      printf '%s\n' 'wp-includes'
      ;;
    *)
      _source_policy_all_roots
      ;;
  esac
}

# Roots the agent may edit in place under the active posture.
source_policy_editable_roots() {
  case "${POSTURE:-$SOURCE_POLICY_DEFAULT_POSTURE}" in
    managed)
      printf '%s\n' 'wp-content/plugins' 'wp-content/themes'
      ;;
    *)
      : # engineering edits nothing in the installed tree
      ;;
  esac
}

# Whether the Data Machine Code workspace (and therefore git/GitHub) is part of
# this install's architecture.
#
# Consumed by the runtimes (workspace allow rules) and by lib/data-machine.sh
# (whether data-machine-code is installed at all). Returns 0 for yes.
source_policy_workspace_enabled() {
  case "${POSTURE:-$SOURCE_POLICY_DEFAULT_POSTURE}" in
    managed) return 1 ;;
    *) return 0 ;;
  esac
}

# Every managed root paired with its action under the active posture, as
# tab-separated `<root>\t<deny|allow>` lines in canonical root order.
#
# This is the shape the runtimes consume. Policy lives here; FORMATTING stays in
# each runtime, because each one has its own config dialect (OpenCode JSON,
# Claude Code Edit() globs, Codex TOML filesystem profiles). Emitting every root
# rather than only the denied ones means an install that switches posture has
# the same key set rewritten rather than stale keys left behind.
source_policy_root_actions() {
  local root
  local read_only
  read_only="$(source_policy_read_only_roots)"

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if printf '%s\n' "$read_only" | grep -qxF "$root"; then
      printf '%s\tdeny\n' "$root"
    else
      printf '%s\tallow\n' "$root"
    fi
  done < <(_source_policy_all_roots)
}
