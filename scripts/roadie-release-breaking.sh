#!/bin/bash
# scripts/roadie-release-breaking.sh — does the Roadie release range carry a
# breaking change?
#
# Usage: roadie-release-breaking.sh <from-version> <to-version>
# (plain versions, e.g. 0.58.2 0.60.0)
#
# The Roadie pin refresh must not push a release that changes the installer's
# startup contract straight to main (#731). A release is breaking when the
# range carries one of:
#
#   1. a conventional-commit breaking marker in any commit message
#      (`feat!:`/`feat(scope)!:` or a `BREAKING CHANGE` footer),
#   2. a breaking marker in the target release's notes,
#   3. a minor bump while Roadie is 0.x (the release itself may not have
#      flagged it; 0.x minors routinely carry behavior changes).
#
# Exit 0 = breaking (reasons on stdout, one per line).
# Exit 1 = not breaking. Exit 2 = cannot decide (API failure); callers must
# treat an undecided range as breaking.

REPO="${ROADIE_RELEASE_REPO:-Extra-Chill/roadie}"

usage() { echo "usage: $0 <from-version> <to-version>" >&2; exit 2; }

is_version() { printf '%s' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; }

[ $# -eq 2 ] || usage
from="$1" to="$2"
is_version "$from" || usage
is_version "$to" || usage

declare -a reasons=()

# --- 3. minor bump while Roadie is 0.x -------------------------------------
from_major="${from%%.*}" to_major="${to%%.*}"
from_minor="$(cut -d. -f2 <<<"$from")" to_minor="$(cut -d. -f2 <<<"$to")"
if [ "$from_major" = 0 ] && [ "$to_major" = 0 ] && [ "$from_minor" != "$to_minor" ]; then
  reasons+=("minor bump in 0.x: v$from -> v$to")
fi

# --- 1. breaking markers in commit messages across the range ---------------
if compare="$(gh api "repos/$REPO/compare/v$from...v$to" --jq '.commits[].commit.message' 2>/dev/null)"; then
  # Subject lines like `feat!:` / `feat(scope)!:` on their own line.
  if printf '%s\n' "$compare" | grep -Eq '^(feat|fix|perf|refactor)(\([^)]+\))?!:'; then
    subject="$(printf '%s\n' "$compare" | grep -E '^(feat|fix|perf|refactor)(\([^)]+\))?!:' | head -n1)"
    reasons+=("breaking commit: $subject")
  fi
  # `BREAKING CHANGE` / `BREAKING-CHANGE` footers on their own line.
  if printf '%s\n' "$compare" | grep -Eq '^BREAKING[ -]CHANGE'; then
    reasons+=("BREAKING CHANGE footer in the v$from...v$to range")
  fi
else
  reasons+=("could not read the v$from...v$to commit range; treating as breaking")
fi

# --- 2. breaking markers in the target release's notes ---------------------
if notes="$(gh api "repos/$REPO/releases/tags/v$to" --jq .body 2>/dev/null)"; then
  if printf '%s\n' "$notes" | grep -Eqi '^#+ .*breaking|BREAKING[ -]CHANGE|^(feat|fix|perf|refactor)(\([^)]+\))?!:'; then
    reasons+=("breaking marker in the v$to release notes")
  fi
else
  reasons+=("could not read the v$to release notes; treating as breaking")
fi

if [ ${#reasons[@]} -gt 0 ]; then
  for reason in "${reasons[@]}"; do
    echo "$reason"
  done
  exit 0
fi
exit 1
