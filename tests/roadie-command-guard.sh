#!/usr/bin/env bash
# tests/roadie-command-guard.sh — managed-runtime ownership guard for Roadie.
#
# Unit cases always run. The live probe runs against a real OpenCode when one
# is on PATH (CI installs the supported fixture version).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node "$ROOT/tests/roadie-command-guard.mjs"
if command -v "${OPENCODE_BIN:-opencode}" >/dev/null 2>&1; then
  node "$ROOT/tests/roadie-command-guard-live.mjs"
else
  echo "skip live OpenCode guard probe (opencode not installed)"
fi
