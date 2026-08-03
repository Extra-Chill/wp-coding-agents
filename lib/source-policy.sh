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
# Newline-separated wp-content paths the site owns under managed posture.
SOURCE_POLICY_OWNED_OPTION="wp_coding_agents_managed_sources"
# Paths that are editable but NOT captured. Distinct from owned sources on
# purpose: --managed-source means "editable AND recorded by the operator's
# capture", which is what makes the guidance's "your work is recorded" promise
# true. wp-config.php and friends are not captured by a component harvest, so
# declaring them as sources would have AGENTS.md assert a safety property that
# does not hold for them — the #318 failure. They get their own category and
# their own, honest, prose.
SOURCE_POLICY_WRITABLE_OPTION="wp_coding_agents_managed_writable"
# Paths OUTSIDE the site root the agent may read — server logs, almost always.
#
# This exists because the limitation was backwards. We are strict about editing
# core (correct: an update overwrites it anyway) and were accidentally strict
# about READING the one thing needed to recover from a fatal. OpenCode gates
# anything touching a path outside the project directory behind
# `external_directory`, which defaults to "ask" — and an autonomous agent has
# nobody to ask. So on a live site the single most important recovery
# capability sat behind a prompt that could never be answered.
#
# Read only. These are granted through external_directory and then explicitly
# denied for edit, so the agent can diagnose without rewriting a log.
SOURCE_POLICY_LOG_OPTION="wp_coding_agents_log_paths"

# Every installed-source root wp-coding-agents has an opinion about, in the
# order they are emitted by every consumer. Adding a root here adds it to all
# runtimes and to the AGENTS.md prose at once.
# Every installed path wp-coding-agents has an opinion about, as
# `<path>\t<dir|file>` lines in canonical order.
#
# The kind matters because the three runtimes format these differently, and
# because of a glob trap: OpenCode's matcher turns `*` into `.*`, which SPANS
# SLASHES (packages/opencode/src/util/wildcard.ts). A pattern like `wp-*.php`
# meant for root bootstrap files would therefore also match
# `wp-content/plugins/acme/wp-thing.php` and over-deny inside a site's own
# component. Root files must be exact literals; `Wildcard.match` anchors ^...$
# so a literal matches only that exact relative path.
#
# WordPress core is `wp-admin/` AND `wp-includes/` plus the root bootstrap —
# they are siblings, not nested. Listing only wp-includes (the historical
# behavior) left wp-admin and every root PHP file, including wp-config.php,
# editable on every install.
#
# `wp-content/mu-plugins/` is here because it is AGENT GOVERNANCE, not a site
# extension: wp-coding-agents installs the mu-plugin that GENERATES AGENTS.md
# there, alongside the channel and runtime registries. An agent able to edit
# that directory can rewrite its own instructions. Same reasoning as
# wp-config.php, which holds the constants that gate composition at all.
#
# `wp-content/uploads/` is deliberately NOT here. The agent's own memory files
# live under it and it has to be able to write them.
_source_policy_all_roots() {
  printf '%s\n' \
    'wp-admin	dir' \
    'wp-includes	dir' \
    'wp-content/plugins	dir' \
    'wp-content/themes	dir' \
    'wp-content/mu-plugins	dir' \
    'wp-config.php	file' \
    'wp-settings.php	file' \
    'wp-load.php	file' \
    'wp-blog-header.php	file' \
    'wp-cron.php	file' \
    'wp-login.php	file' \
    'wp-mail.php	file' \
    'wp-signup.php	file' \
    'wp-activate.php	file' \
    'wp-trackback.php	file' \
    'wp-comments-post.php	file' \
    'wp-links-opml.php	file' \
    'xmlrpc.php	file' \
    'index.php	file'
}

# Just the paths, for callers that do not care about the kind.
_source_policy_all_root_paths() {
  _source_policy_all_roots | cut -f1
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

# Roots the agent must NOT edit, under EITHER posture.
#
# This is deliberately every root in both postures. `wp-content/plugins/` holds
# WooCommerce, payment gateways, and the agent's own Data Machine runtime;
# `wp-content/themes/` holds the stock bundled themes. None of those belong to
# the site owner, none are captured by the operator's harvest, and editing them
# in place produces a change that is destroyed by the next update.
#
# Managed hosting does not open these directories. It opens specific declared
# paths INSIDE them — see source_policy_owned_sources.
source_policy_read_only_roots() {
  _source_policy_all_roots
}

# Paths the agent may edit in place, relative to the WordPress root.
#
# Empty under engineering. Under managed this is the explicitly declared set of
# source trees the site owns, e.g.:
#
#   wp-content/themes/acme-theme
#   wp-content/plugins/acme-core
#
# INVARIANT: the editable set must equal the set captured by the operator's
# out-of-band harvest. A path the agent may edit but nothing records is a path
# where the agent silently loses work — and on a live site that failure is
# invisible until an update overwrites it. Declaring these explicitly is what
# keeps the two sets in agreement; there is no reliable way to infer which
# plugins a site "owns" by inspection, and guessing wrong on a production site
# is not an acceptable default.
source_policy_owned_sources() {
  if ! source_policy_is_managed; then
    return 0
  fi

  printf '%s\n' "${MANAGED_SOURCES:-}" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done
}

# Declared editable-but-not-captured paths. Empty unless managed.
source_policy_writable_paths() {
  if ! source_policy_is_managed; then
    return 0
  fi

  printf '%s\n' "${MANAGED_WRITABLE:-}" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done
}

# Declared read-only paths outside the site root.
source_policy_log_paths() {
  printf '%s\n' "${MANAGED_LOG_PATHS:-}" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done
}

source_policy_resolve_log_paths() {
  if [ "${MANAGED_LOG_PATHS_EXPLICIT:-false}" = true ]; then
    MANAGED_LOG_PATHS="$(_source_policy_normalize_log_paths "${MANAGED_LOG_PATHS:-}")"
  else
    MANAGED_LOG_PATHS="$(_source_policy_normalize_log_paths "$(source_policy_recorded_log_paths)")"
  fi
}

source_policy_recorded_log_paths() {
  if [ "${DRY_RUN:-false}" = true ]; then
    printf '%s' "${MANAGED_LOG_PATHS:-}"
    return 0
  fi
  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi
  wp_cmd option get "$SOURCE_POLICY_LOG_OPTION" 2>/dev/null || true
}

source_policy_record_log_paths() {
  local paths="${MANAGED_LOG_PATHS:-}"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update $SOURCE_POLICY_LOG_OPTION '<${paths}>'"
    return 0
  fi
  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi
  if [ "$(source_policy_recorded_log_paths)" = "$paths" ]; then
    return 0
  fi
  if printf '%s' "$paths" | wp_cmd option update "$SOURCE_POLICY_LOG_OPTION" >/dev/null 2>&1; then
    log "  Recorded readable log paths: $(printf '%s' "$paths" | tr '\n' ' ')"
  else
    warn "Could not record readable log paths"
  fi
}

# Must be absolute. A relative path here would be inside the site root, where
# external_directory does not apply and the grant would silently do nothing.
_source_policy_normalize_log_paths() {
  printf '%s\n' "${1:-}" | tr ' ' '\n' | while IFS= read -r path; do
    path="${path%/}"
    [ -n "$path" ] || continue
    case "$path" in
      /*) ;;
      *)
        warn "  Ignoring log path '$path': must be absolute" >&2
        continue
        ;;
    esac
    printf '%s\n' "$path"
  done
}

source_policy_is_managed() {
  [ "${POSTURE:-$SOURCE_POLICY_DEFAULT_POSTURE}" = managed ]
}

# Resolve the declared owned-source set into MANAGED_SOURCES.
#
# Precedence mirrors posture: explicit --managed-source flags, then the set
# recorded on the install, then nothing.
source_policy_resolve_owned_sources() {
  if ! source_policy_is_managed; then
    MANAGED_SOURCES=""
    return 0
  fi

  if [ "${MANAGED_SOURCES_EXPLICIT:-false}" = true ]; then
    MANAGED_SOURCES="$(_source_policy_normalize_sources "${MANAGED_SOURCES:-}")"
  else
    MANAGED_SOURCES="$(_source_policy_normalize_sources "$(source_policy_recorded_owned_sources)")"
  fi

  if [ -z "$MANAGED_SOURCES" ]; then
    # FAIL CLOSED. A managed install with nothing declared must not fall back
    # to opening wp-content wholesale; that is how a coding agent ends up with
    # write access to a payment gateway. Deny everything and make the operator
    # say what the site owns.
    warn "Managed posture with no --managed-source declared: the agent will have NO editable source."
    warn "Declare the site's own theme and plugins, for example:"
    warn "  --managed-source wp-content/themes/<theme> --managed-source wp-content/plugins/<plugin>"
    warn "These must match what the operator's harvest captures."
  fi
}

source_policy_resolve_writable_paths() {
  if ! source_policy_is_managed; then
    MANAGED_WRITABLE=""
    return 0
  fi

  if [ "${MANAGED_WRITABLE_EXPLICIT:-false}" = true ]; then
    MANAGED_WRITABLE="$(_source_policy_normalize_writable "${MANAGED_WRITABLE:-}")"
  else
    MANAGED_WRITABLE="$(_source_policy_normalize_writable "$(source_policy_recorded_writable_paths)")"
  fi
}

source_policy_recorded_writable_paths() {
  if [ "${DRY_RUN:-false}" = true ]; then
    printf '%s' "${MANAGED_WRITABLE:-}"
    return 0
  fi
  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi
  wp_cmd option get "$SOURCE_POLICY_WRITABLE_OPTION" 2>/dev/null || true
}

source_policy_record_writable_paths() {
  source_policy_is_managed || return 0
  local paths="${MANAGED_WRITABLE:-}"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update $SOURCE_POLICY_WRITABLE_OPTION '<${paths}>'"
    return 0
  fi
  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi
  if [ "$(source_policy_recorded_writable_paths)" = "$paths" ]; then
    return 0
  fi
  if printf '%s' "$paths" | wp_cmd option update "$SOURCE_POLICY_WRITABLE_OPTION" >/dev/null 2>&1; then
    log "  Recorded managed writable paths: $(printf '%s' "$paths" | tr '\n' ' ')"
  else
    warn "Could not record managed writable paths"
  fi
}

# Writable exceptions must name a path the policy actually denies; anything
# else is either already editable or a typo, and silently accepting it would
# leave the operator believing they granted something they did not.
_source_policy_normalize_writable() {
  local known
  known="$(_source_policy_all_root_paths)"
  printf '%s\n' "${1:-}" | tr ' ' '\n' | while IFS= read -r path; do
    path="${path#./}"; path="${path#/}"; path="${path%/}"
    [ -n "$path" ] || continue
    if ! printf '%s\n' "$known" | grep -qxF "$path"; then
      warn "  Ignoring writable path '$path': not one of the paths this policy denies" >&2
      continue
    fi
    printf '%s\n' "$path"
  done
}

_source_policy_normalize_sources() {
  printf '%s\n' "${1:-}" | tr ' ' '\n' | while IFS= read -r path; do
    path="${path#./}"
    path="${path#/}"
    path="${path%/}"
    [ -n "$path" ] || continue
    case "$path" in
      wp-content/plugins/*/*|wp-content/themes/*/*)
        warn "  Ignoring managed source '$path': declare the plugin or theme directory itself, not a file inside it" >&2
        continue
        ;;
      wp-content/plugins/*|wp-content/themes/*) ;;
      *)
        warn "  Ignoring managed source '$path': must be under wp-content/plugins/ or wp-content/themes/" >&2
        continue
        ;;
    esac
    printf '%s\n' "$path"
  done
}

source_policy_recorded_owned_sources() {
  if [ "${DRY_RUN:-false}" = true ]; then
    printf '%s' "${MANAGED_SOURCES:-}"
    return 0
  fi

  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi

  wp_cmd option get "$SOURCE_POLICY_OWNED_OPTION" 2>/dev/null || true
}

source_policy_record_owned_sources() {
  if ! source_policy_is_managed; then
    return 0
  fi

  local sources="${MANAGED_SOURCES:-}"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update $SOURCE_POLICY_OWNED_OPTION '<${sources}>'"
    return 0
  fi

  if [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi

  if [ "$(source_policy_recorded_owned_sources)" = "$sources" ]; then
    return 0
  fi

  if printf '%s' "$sources" | wp_cmd option update "$SOURCE_POLICY_OWNED_OPTION" >/dev/null 2>&1; then
    log "  Recorded managed sources: $(printf '%s' "$sources" | tr '\n' ' ')"
    if [ -n "${UPDATED_ITEMS+x}" ]; then
      UPDATED_ITEMS+=("managed sources")
    fi
  else
    warn "Could not record managed sources — upgrades will fall back to the recorded value or none"
  fi
}

# Runtimes whose permission model can express "deny a directory, then allow
# specific paths inside it".
#
# OpenCode can: permission evaluation is `findLast` over a ruleset built in JSON
# key order (packages/opencode/src/permission/index.ts), so a narrower allow
# written AFTER a broad deny wins. Key order is therefore load-bearing.
#
# Claude Code cannot: deny is absolute and an allow never overrides it, so the
# same shape would leave the owned paths unusable. Codex filesystem profiles
# have no documented precedence for overlapping entries either. Rather than emit
# a permission set whose behavior is unverified on a live production site, those
# runtimes refuse managed posture outright.
source_policy_runtime_supports_managed() {
  case "${1:-${RUNTIME:-}}" in
    opencode) return 0 ;;
    *) return 1 ;;
  esac
}

source_policy_assert_runtime_supports_posture() {
  if ! source_policy_is_managed; then
    return 0
  fi

  if source_policy_runtime_supports_managed "${RUNTIME:-}"; then
    return 0
  fi

  error "Managed posture is not supported on the '${RUNTIME:-unknown}' runtime yet — only 'opencode' can express scoped source permissions safely. See lib/source-policy.sh."
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

# The ordered edit ruleset for the active posture, as tab-separated
# `<path>\t<deny|allow>` lines.
#
# ORDER IS LOAD-BEARING. OpenCode resolves permissions with `findLast` over a
# ruleset built in JSON key order, so every broad deny must be emitted BEFORE
# the narrower allows that carve exceptions out of it. Consumers must preserve
# this order verbatim.
#
# Engineering emits three denies and nothing else, which is byte-identical to
# the pre-posture behavior. Managed emits the same three denies, then one allow
# per declared owned source.
source_policy_edit_rules() {
  local path kind
  local writable owned

  # Denies first. ORDER IS LOAD-BEARING: OpenCode resolves with findLast over a
  # ruleset built in config key order, so every broad deny must precede the
  # narrower allows that carve exceptions out of it.
  while IFS=$'\t' read -r path kind; do
    [ -n "$path" ] || continue
    printf '%s\t%s\tdeny\n' "$path" "$kind"
  done < <(source_policy_read_only_roots)

  # Owned source trees: editable AND captured.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\tdir\tallow\n' "$path"
  done < <(source_policy_owned_sources)

  # Declared exceptions: editable, NOT captured.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\tfile\tallow\n' "$path"
  done < <(source_policy_writable_paths)
}

# Render one rule path for a runtime that uses glob patterns (OpenCode,
# Claude Code). Directories get /**; files stay literal so they anchor to the
# site root instead of matching same-named files inside components.
source_policy_pattern() {
  local path="$1" kind="$2"
  if [ "$kind" = dir ]; then
    printf '%s/**' "$path"
  else
    printf '%s' "$path"
  fi
}
