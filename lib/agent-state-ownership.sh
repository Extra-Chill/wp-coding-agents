#!/bin/bash
# Agent-maintained state must be owned by the service identity (#598).
#
# setup.sh historically defaulted to running as root while the agent itself
# runs as a dedicated service user. Everything setup wrote for the *agent* to
# keep current — the persistent Kimaki config, runtime config under the site,
# the installation profile — was left root-owned, so every later non-root
# upgrade degraded into per-file "Permission denied" noise and silently kept
# stale plugin sources, skills, and hooks. Ownership of agent state follows the
# service identity, not whichever uid happened to invoke the installer.
#
# Two entry points:
#   agent_state_ownership_reconcile  as root: hand every agent-state root to
#                                    SERVICE_USER once, preserving the site
#                                    group so www-data keeps its reach.
#   agent_state_ownership_audit      as the service user: report, in one
#                                    consolidated record, which roots are still
#                                    not writable, and the exact command that
#                                    repairs them. Never mutates.
#
# Genuinely privileged host state (systemd units, sudoers, journald) is NOT
# agent state and is deliberately not listed here; that stays behind the
# systems-capabilities root-repair handoff.

AGENT_STATE_OWNERSHIP_ROOT_REPAIR_REQUIRED=false
AGENT_STATE_OWNERSHIP_ROOT_REPAIR_COMMAND=""
AGENT_STATE_OWNERSHIP_UNWRITABLE=()

# Roots the agent maintains, one per line. Only paths that exist are emitted.
agent_state_ownership_roots() {
  local site="${SITE_PATH:-${EXISTING_WP:-}}"
  local candidate
  for candidate in \
    "${RESOLVED_KIMAKI_CONFIG_DIR:-/opt/kimaki-config}" \
    "${site:+$site/.wp-coding-agents}" \
    "${site:+$site/.opencode}" \
    "${site:+$site/.claude}" \
    "${site:+$site/.codex}"; do
    [ -n "$candidate" ] || continue
    [ -e "$candidate" ] || continue
    [ -L "$candidate" ] && continue
    printf '%s\n' "$candidate"
  done
}

# The service identity that should own agent state, or empty when ownership
# reconciliation does not apply (local mode, root service, unresolved user).
agent_state_ownership_target_user() {
  [ "${LOCAL_MODE:-false}" = false ] || return 0
  local user="${SERVICE_USER:-}"
  [ -n "$user" ] && [ "$user" != root ] || return 0
  id -u "$user" >/dev/null 2>&1 || return 0
  printf '%s' "$user"
}

# Group to pair with the service user for a given root: the site group when the
# root lives under the site (so www-data keeps its access), otherwise the
# service user's primary group.
agent_state_ownership_group_for() {
  local root="$1" user="$2" site="${SITE_PATH:-${EXISTING_WP:-}}" group=""
  if [ -n "$site" ]; then
    case "$root" in
      "$site"/*) group="$(file_group "$site" 2>/dev/null || true)" ;;
    esac
  fi
  [ -n "$group" ] || group="$(id -gn "$user" 2>/dev/null || printf '%s' "$user")"
  printf '%s' "$group"
}

# Root-only: reassign every agent-state root to the service identity. Idempotent
# and cheap when nothing is root-owned. Returns the number of roots changed via
# AGENT_STATE_OWNERSHIP_CHANGED.
agent_state_ownership_reconcile() {
  AGENT_STATE_OWNERSHIP_CHANGED=0
  local user root group
  user="$(agent_state_ownership_target_user)"
  [ -n "$user" ] || return 0
  [ "$(id -u)" -eq 0 ] || return 0

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    # Skip roots already fully owned by the service user.
    if [ -z "$(find "$root" ! -user "$user" -print -quit 2>/dev/null)" ]; then
      continue
    fi
    group="$(agent_state_ownership_group_for "$root" "$user")"
    if [ "${DRY_RUN:-false}" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} chown -R $user:$group $root"
    else
      chown -R "$user:$group" "$root" 2>/dev/null || {
        warn "[agent-state] could not reassign $root to $user:$group"
        continue
      }
    fi
    AGENT_STATE_OWNERSHIP_CHANGED=$((AGENT_STATE_OWNERSHIP_CHANGED + 1))
    log "[agent-state] $root -> $user:$group"
  done <<<"$(agent_state_ownership_roots)"

  if [ "$AGENT_STATE_OWNERSHIP_CHANGED" -gt 0 ]; then
    UPDATED_ITEMS+=("Agent state ownership reconciled to $user ($AGENT_STATE_OWNERSHIP_CHANGED root(s))")
  fi
  return 0
}

# Non-root: find agent-state roots the current identity cannot maintain and
# emit ONE consolidated root-repair record instead of letting each later phase
# fail on its own file. Never mutates.
agent_state_ownership_audit() {
  AGENT_STATE_OWNERSHIP_ROOT_REPAIR_REQUIRED=false
  AGENT_STATE_OWNERSHIP_ROOT_REPAIR_COMMAND=""
  AGENT_STATE_OWNERSHIP_UNWRITABLE=()
  [ "${LOCAL_MODE:-false}" = false ] || return 0
  [ "$(id -u)" -ne 0 ] || return 0

  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if ! agent_state_ownership_root_maintainable "$root"; then
      AGENT_STATE_OWNERSHIP_UNWRITABLE+=("$root")
    fi
  done <<<"$(agent_state_ownership_roots)"

  [ "${#AGENT_STATE_OWNERSHIP_UNWRITABLE[@]}" -gt 0 ] || return 0

  AGENT_STATE_OWNERSHIP_ROOT_REPAIR_REQUIRED=true
  AGENT_STATE_OWNERSHIP_ROOT_REPAIR_COMMAND="sudo $(agent_state_ownership_upgrade_invocation) --reconcile-agent-state-ownership"
  warn "[agent-state] root-owned agent state found; this non-root upgrade cannot maintain:"
  for root in "${AGENT_STATE_OWNERSHIP_UNWRITABLE[@]}"; do
    warn "[agent-state]   $root (owner: $(file_owner "$root" 2>/dev/null || echo unknown))"
  done
  warn "[agent-state] one-time repair: $AGENT_STATE_OWNERSHIP_ROOT_REPAIR_COMMAND"
  printf '{"status":"root_repair_required","component":"agent_state_ownership","paths":[%s],"repair_command":"%s"}\n' \
    "$(agent_state_ownership_json_list "${AGENT_STATE_OWNERSHIP_UNWRITABLE[@]}")" \
    "$(json_escape "$AGENT_STATE_OWNERSHIP_ROOT_REPAIR_COMMAND")"
  return 0
}

# A root is maintainable when everything under it is owned by the current
# identity. Group-writability is not enough: a root-owned file the service
# user can write but cannot chmod (the hook that must be +x) still breaks the
# sync, and only the owner can change modes.
agent_state_ownership_root_maintainable() {
  local root="$1" uid="${AGENT_STATE_OWNERSHIP_UID:-$(id -u)}"
  [ -z "$(find "$root" ! -uid "$uid" -print -quit 2>/dev/null)" ]
}

# Whether a given path is one this identity can maintain right now. Phases that
# write into agent state use this to skip cleanly (one warning already emitted
# by the audit) instead of spraying cp/chmod errors.
agent_state_ownership_can_maintain() {
  local path="$1" root
  [ "${#AGENT_STATE_OWNERSHIP_UNWRITABLE[@]}" -gt 0 ] || return 0
  for root in "${AGENT_STATE_OWNERSHIP_UNWRITABLE[@]}"; do
    case "$path" in
      "$root"|"$root"/*) return 1 ;;
    esac
  done
  return 0
}

agent_state_ownership_upgrade_invocation() {
  local script="${SCRIPT_DIR:-.}/upgrade.sh"
  printf '%s --wp-path %s' "$script" "${SITE_PATH:-${EXISTING_WP:-}}"
}

agent_state_ownership_json_list() {
  local first=true item
  for item in "$@"; do
    [ "$first" = true ] || printf ','
    first=false
    printf '"%s"' "$(json_escape "$item")"
  done
}
