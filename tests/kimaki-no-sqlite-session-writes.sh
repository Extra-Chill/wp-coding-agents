#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -R -n -E 'thread_(sessions|worktrees)|sqlite3' "$ROOT/bridges/kimaki/bin"; then
  echo "FAIL: Kimaki bridge bin scripts must not write Kimaki internal SQLite session tables" >&2
  exit 1
fi

echo "OK: Kimaki bridge bin scripts avoid direct Kimaki SQLite session writes"
