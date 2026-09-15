#!/bin/bash
# tests/install-source-integrity-report.sh - stale install sources are reported.
#
# Builds real git checkouts in a temp dir and asserts what the reporter says
# about them. The regression this guards is an upgrade run from a checkout far
# behind the default branch, which reinstalls stale managed files while
# reporting success.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

# Origin with two commits on main.
git_quiet init --bare "$WORK/origin.git"
git_quiet clone "$WORK/origin.git" "$WORK/checkout"
cd "$WORK/checkout"
printf 'v1\n' >artifact.txt
git_quiet add -A && git_quiet commit -m first
git_quiet push -u origin main
printf 'v2\n' >artifact.txt
git_quiet add -A && git_quiet commit -m second
git_quiet push origin main

# report <script_dir> -> stdout+stderr of the reporter for that checkout
report() {
  SCRIPT_DIR="$1" bash -c '
    set -eu
    source "'"$REPO_ROOT"'/lib/common.sh"
    source "'"$REPO_ROOT"'/lib/install-source.sh"
    install_source_report_integrity
  ' 2>&1
}

# --- clean default branch is silent ------------------------------------------
out="$(report "$WORK/checkout")"
[ -z "$out" ] || fail "clean default-branch checkout should report nothing, got: $out"

# --- checkout behind the default branch is reported --------------------------
git_quiet checkout -b feat/stale HEAD~1
out="$(report "$WORK/checkout")"
case "$out" in
  *"behind"*) ;;
  *) fail "stale checkout did not report being behind, got: $out" ;;
esac
case "$out" in
  *"feat/stale"*) ;;
  *) fail "stale checkout did not name the current branch, got: $out" ;;
esac

# --- uncommitted changes are reported ----------------------------------------
git_quiet checkout main
printf 'local-edit\n' >>artifact.txt
out="$(report "$WORK/checkout")"
case "$out" in
  *"dirty"*) ;;
  *) fail "dirty checkout did not report uncommitted paths, got: $out" ;;
esac
git_quiet checkout -- artifact.txt

# --- non-git source is silent, not fatal -------------------------------------
mkdir -p "$WORK/plain"
out="$(report "$WORK/plain")"
[ -z "$out" ] || fail "non-git install source should report nothing, got: $out"

echo "PASS: tests/install-source-integrity-report.sh"
