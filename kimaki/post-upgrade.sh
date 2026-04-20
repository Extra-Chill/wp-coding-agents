#!/usr/bin/env bash
# post-upgrade.sh — Remove unwanted bundled Kimaki skills.
#
# Invoked two ways:
#   VPS:   ExecStartPre in kimaki.service (runs on every service start).
#   Local: upgrade.sh runs it inline after copying plugins (no launchd hook).
#
# Skills dir resolution priority:
#   1. KIMAKI_SKILLS_DIR env var (explicit override)
#   2. $(npm root -g)/kimaki/skills (works on macOS + Linux when npm is on PATH)
#   3. /usr/lib/node_modules/kimaki/skills (Linux VPS fallback when npm absent)
set -euo pipefail

if [[ -n "${KIMAKI_SKILLS_DIR:-}" ]]; then
  SKILLS_DIR="$KIMAKI_SKILLS_DIR"
elif command -v npm &>/dev/null; then
  NPM_ROOT="$(npm root -g 2>/dev/null || true)"
  if [[ -n "$NPM_ROOT" ]]; then
    SKILLS_DIR="$NPM_ROOT/kimaki/skills"
  else
    SKILLS_DIR="/usr/lib/node_modules/kimaki/skills"
  fi
else
  SKILLS_DIR="/usr/lib/node_modules/kimaki/skills"
fi

KILL_LIST="$(dirname "$0")/skills-kill-list.txt"

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "kimaki-config: skills dir not found at $SKILLS_DIR, skipping"
  exit 0
fi

if [[ ! -f "$KILL_LIST" ]]; then
  echo "kimaki-config: kill list not found at $KILL_LIST, skipping"
  exit 0
fi

removed=0
while IFS= read -r skill || [[ -n "$skill" ]]; do
  # Skip comments and blank lines
  [[ -z "$skill" || "$skill" == \#* ]] && continue
  target="$SKILLS_DIR/$skill"
  if [[ -d "$target" ]]; then
    rm -rf "$target"
    echo "kimaki-config: removed $skill"
    removed=$((removed + 1))
  fi
done < "$KILL_LIST"

echo "kimaki-config: done ($removed skills removed)"
