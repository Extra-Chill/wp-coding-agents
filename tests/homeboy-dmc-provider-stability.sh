#!/bin/bash
# tests/homeboy-dmc-provider-stability.sh — Homeboy DMC provider commands must
# not resolve inside a disposable git worktree (#482).
#
# A live config was found pinning `worktree_providers.dmc.commands` at a
# feature-branch task worktree of wp-coding-agents itself. Once that branch
# merged and the worktree was cleaned up, every DMC worktree operation broke
# at once, because all of them route through that one path. This asserts the
# setup/upgrade tooling actually notices and reacts when it is about to do
# that again, rather than asserting anything about how it notices.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local needle="$1" haystack="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "FAIL: expected '$needle' in: $haystack"
      exit 1
      ;;
  esac
}

# Build a real primary checkout and a real linked task worktree off it — the
# same relationship `datamachine-code workspace worktree add` creates for
# every fanout task, and the same relationship this project's own
# contributors create by hand with `git worktree add ../repo@branch`.
PRIMARY="$TMP/wp-coding-agents"
mkdir -p "$PRIMARY"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" config user.email test@example.com
git -C "$PRIMARY" config user.name test
: > "$PRIMARY/marker"
git -C "$PRIMARY" add marker
git -C "$PRIMARY" commit -q -m init
TASK_WORKTREE="$TMP/wp-coding-agents@fix-482-provider-path-stability"
git -C "$PRIMARY" worktree add -q -b fix-482-provider-path-stability "$TASK_WORKTREE" >/dev/null 2>&1

# An installed release payload has no .git at all — nothing for `git
# worktree` to have cleaned up, so it is inherently stable.
PLAIN="$TMP/installed-release"
mkdir -p "$PLAIN"

HOMEBOY_MODE=auto
WITH_HOMEBOY=false

output="$(homeboy_dmc_guard_script_dir_stability "$PLAIN")"
[ -z "$output" ] || {
  echo "FAIL: a non-git script dir must not be flagged: $output"
  exit 1
}

output="$(homeboy_dmc_guard_script_dir_stability "$PRIMARY")"
[ -z "$output" ] || {
  echo "FAIL: the primary checkout must not be flagged: $output"
  exit 1
}

# A linked task worktree must be flagged. In auto mode (the default; setup and
# upgrade never pass --with-homeboy unless a human asks for it) this is a
# warning, not a hard failure — the caller still writes the provider config,
# same as every other soft Homeboy failure in this file.
output="$(homeboy_dmc_guard_script_dir_stability "$TASK_WORKTREE")"
assert_contains "$TASK_WORKTREE" "$output"
assert_contains "disposable task worktree" "$output"
assert_contains "primary wp-coding-agents checkout" "$output"

# When Homeboy is explicitly required (--with-homeboy / HOMEBOY_MODE=enabled),
# the same condition must refuse outright rather than silently pin production
# config to a checkout that workspace cleanup is entitled to delete.
HOMEBOY_MODE=enabled
set +e
( homeboy_dmc_guard_script_dir_stability "$TASK_WORKTREE" ) > "$TMP/required.out" 2>&1
required_status=$?
set -e
HOMEBOY_MODE=auto
[ "$required_status" -ne 0 ] || {
  echo "FAIL: --with-homeboy must refuse a task-worktree script dir"
  cat "$TMP/required.out"
  exit 1
}
assert_contains "$TASK_WORKTREE" "$(cat "$TMP/required.out")"

# End-to-end: configure_homeboy_dmc_worktree_provider must reach and surface
# the same guard before anything else, including its own unrelated soft
# skips (exercised here with homeboy absent from PATH).
FAKE_BIN="$TMP/sandbin"
mkdir -p "$FAKE_BIN"
for tool in grep cat rm git; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$FAKE_BIN/$tool"
done
SCRIPT_DIR="$TASK_WORKTREE"
PATH="$FAKE_BIN"
apply_output="$(configure_homeboy_dmc_worktree_provider)"
assert_contains "disposable task worktree" "$apply_output"
assert_contains "Homeboy is not callable" "$apply_output"

echo "OK: Homeboy DMC provider setup flags a disposable task worktree script dir (#482)"
