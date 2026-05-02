#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bridges/kimaki/bin/datamachine-kimaki-session"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

primary="$TMP/repo"
worktree="$TMP/repo@helper-smoke"

git init -q "$primary"
git -C "$primary" -c user.name='Test User' -c user.email='test@example.test' commit --allow-empty -qm 'initial'
git -C "$primary" worktree add -q -b helper-smoke "$worktree"

output="$($HELPER \
  --channel 123456789 \
  --cwd "$worktree" \
  --prompt 'Smoke helper handoff' \
  --data-dir "$TMP/kimaki" \
  --dry-run)"

case "$output" in
  *'"cwd":'*"$worktree"*'"primary":'*"$primary"*'"branch": "helper-smoke"'*)
    echo "kimaki-session-helper smoke: PASS"
    ;;
  *)
    echo "kimaki-session-helper smoke: FAIL" >&2
    echo "$output" >&2
    exit 1
    ;;
esac
