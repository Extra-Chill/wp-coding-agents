#!/bin/bash
# lib/install-source.sh — integrity of the artifacts wp-coding-agents installs.
#
# Every managed file this tool writes to a site is copied out of $SCRIPT_DIR:
#
#   runtimes/opencode/plugins/claude-code-auth.ts
#   skills/, guidance/, bridges/ templates, service units, ...
#
# $SCRIPT_DIR is not a release tarball. It is the operator's working checkout,
# and whatever is in that working tree at the moment `setup.sh` or `upgrade.sh`
# runs is what lands on the site. Two failure modes follow from that, and both
# were silent before this module existed:
#
#   Stale source   The checkout is parked on an old feature branch. Every run
#                  faithfully reinstalls artifacts predating fixes that landed
#                  on the default branch months ago, and the operator sees a
#                  successful upgrade. Observed in the wild: a site pinned to
#                  claude-cli/2.1.75 by repeated upgrades from a checkout 79
#                  commits behind main, long after main shipped 2.1.259.
#                  Anthropic then 400s the session for an unsupported client
#                  version, pointing at the site rather than at the installer.
#
#   Clobber        A managed file the operator hand-edited on the site is
#                  overwritten with no backup and no notice, so the edit simply
#                  evaporates on the next run.
#
# Neither is fixed by pinning a better value somewhere. They are fixed by making
# the installer honest about where its inputs came from and what it destroyed.
#
# Public surface:
#   install_source_report_integrity     # warn when $SCRIPT_DIR is not a clean
#                                       # default-branch release source
#   install_source_sync_managed_file <source> <dest> <label>
#                                       # idempotent copy; backs up a diverged
#                                       # destination before overwriting it
#
# Honors DRY_RUN (logs intent, makes no changes).

# _install_source_git — run git against the install source, quietly.
_install_source_git() {
  git -C "$SCRIPT_DIR" "$@" 2>/dev/null
}

# _install_source_default_branch — the branch releases are cut from.
#
# Reads origin's published HEAD. Falls back to main when origin/HEAD was never
# set locally (a common state for shallow or scripted clones).
_install_source_default_branch() {
  local ref
  ref="$(_install_source_git symbolic-ref refs/remotes/origin/HEAD)" || true
  if [ -n "$ref" ]; then
    printf '%s' "${ref##*/}"
    return 0
  fi
  printf 'main'
}

# install_source_report_integrity — describe the install source when it is not
# a clean checkout of the default branch.
#
# This warns; it never aborts. Developing wp-coding-agents means running
# setup.sh and upgrade.sh from a feature-branch worktree on purpose, and a hard
# failure there would break the tool's own development loop. The bug was never
# that operators install from a branch — it was that they could not tell they
# had. Visibility is the whole fix.
#
# The behind-count is measured against the last-fetched origin ref. No fetch is
# performed here: setup and upgrade should not acquire a network dependency to
# report on local state. A checkout that has not fetched in months can therefore
# under-report how far behind it is, which is called out in the warning.
install_source_report_integrity() {
  _install_source_git rev-parse --git-dir >/dev/null || return 0

  local default_branch current_branch behind dirty_count
  default_branch="$(_install_source_default_branch)"
  current_branch="$(_install_source_git rev-parse --abbrev-ref HEAD)" || current_branch=""
  behind="$(_install_source_git rev-list --count "HEAD..origin/$default_branch")" || behind=""
  dirty_count="$(_install_source_git status --porcelain | grep -c . || true)"

  local off_branch=false stale=false dirty=false
  [ -n "$current_branch" ] && [ "$current_branch" != "$default_branch" ] && off_branch=true
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && stale=true
  [ "$dirty_count" -gt 0 ] 2>/dev/null && dirty=true

  if [ "$off_branch" = false ] && [ "$stale" = false ] && [ "$dirty" = false ]; then
    return 0
  fi

  warn "Installing from a working checkout that is not clean $default_branch:"
  echo "  source:  $SCRIPT_DIR"
  [ "$off_branch" = true ] && echo "  branch:  $current_branch (default is $default_branch)"
  [ "$stale" = true ] && echo "  behind:  $behind commit(s) behind origin/$default_branch as of the last fetch"
  [ "$dirty" = true ] && echo "  dirty:   $dirty_count uncommitted path(s)"
  echo "  Managed files installed by this run come from this tree, not from origin/$default_branch."
}

# install_source_sync_managed_file <source> <dest> <label>
#
# Copy a managed artifact to a site, preserving anything it would destroy.
#
#   identical        no write, no noise, no UPDATED_ITEMS entry
#   destination new  plain install
#   diverged         timestamped .backup.<ts> alongside, then install, and both
#                    the install and the backup path are reported
#
# The backup is unconditional on divergence rather than gated on a heuristic
# for "was this a local edit". There is no reliable way to distinguish an
# operator's hand-edit from an artifact left by an older release, and guessing
# wrong destroys work. A cheap redundant backup is the correct trade; the
# AGENTS.md path in this repo already settled on the same convention.
#
# Returns 0 when the destination ends up matching the source.
install_source_sync_managed_file() {
  local source_path="$1"
  local dest_path="$2"
  local label="${3:-$(basename "$dest_path")}"

  if [ ! -f "$source_path" ]; then
    warn "$label: install source $source_path not found — skipping"
    return 0
  fi

  if [ -f "$dest_path" ] && cmp -s "$source_path" "$dest_path"; then
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    if [ -f "$dest_path" ]; then
      echo -e "${BLUE}[dry-run]${NC} Would back up and replace $label at $dest_path"
    else
      echo -e "${BLUE}[dry-run]${NC} Would install $label at $dest_path"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$dest_path")"

  if [ -f "$dest_path" ]; then
    local backup_path
    backup_path="$dest_path.backup.${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
    cp "$dest_path" "$backup_path"
    UPDATED_ITEMS+=("$label replaced, previous copy saved to $backup_path")
  else
    UPDATED_ITEMS+=("$label ($dest_path)")
  fi

  cp "$source_path" "$dest_path"
  if declare -F service_file_normalize_perms >/dev/null; then
    service_file_normalize_perms "$dest_path"
  fi
}
