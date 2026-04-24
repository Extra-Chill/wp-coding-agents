#!/usr/bin/env bash
# post-upgrade.sh — Enforce kimaki skill state on every restart.
#
# Two symmetric passes run against $(npm root -g)/kimaki/skills/:
#   1. KILL   — remove unwanted bundled kimaki skills listed in skills-kill-list.txt.
#   2. RESTORE — re-copy wp-coding-agents skills from the persistent source dir
#               (kimaki-config/skills/). `npm update -g kimaki` wipes the
#               bundled skills dir, so without this restore pass Discord
#               slash commands silently degrade between upgrades.
#
# Invoked two ways:
#   VPS:   ExecStartPre in kimaki.service (runs on every service start).
#   Local: upgrade.sh runs it inline after copying plugins (no launchd hook).
#
# Skills dir resolution priority:
#   1. KIMAKI_SKILLS_DIR env var (explicit override)
#   2. $(npm root -g)/kimaki/skills (works on macOS + Linux when npm is on PATH)
#   3. /usr/lib/node_modules/kimaki/skills (Linux VPS fallback when npm absent)
#
# Persistent skill source dir resolution priority:
#   1. KIMAKI_SKILL_SOURCE_DIR env var (explicit override)
#   2. $KIMAKI_DATA_DIR/kimaki-config/skills/ if KIMAKI_DATA_DIR set
#   3. $HOME/.kimaki/kimaki-config/skills/ (local default)
#   4. /opt/kimaki-config/skills/ (VPS default)
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

# Restore pass — re-copy wp-coding-agents skills from the persistent source
# dir. Idempotent: `rm -rf` before each `cp -r` so a stale copy in SKILLS_DIR
# always gets replaced by the current source.
if [[ -n "${KIMAKI_SKILL_SOURCE_DIR:-}" ]]; then
  SOURCE_DIR="$KIMAKI_SKILL_SOURCE_DIR"
elif [[ -n "${KIMAKI_DATA_DIR:-}" ]]; then
  SOURCE_DIR="$KIMAKI_DATA_DIR/kimaki-config/skills"
elif [[ -d "$HOME/.kimaki/kimaki-config/skills" ]]; then
  SOURCE_DIR="$HOME/.kimaki/kimaki-config/skills"
else
  SOURCE_DIR="/opt/kimaki-config/skills"
fi

restored=0
if [[ -d "$SOURCE_DIR" ]]; then
  for skill_dir in "$SOURCE_DIR"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    if [[ -f "$skill_dir/SKILL.md" ]]; then
      target="$SKILLS_DIR/$skill_name"
      rm -rf "$target"
      cp -r "$skill_dir" "$target"
      echo "kimaki-config: restored $skill_name"
      restored=$((restored + 1))
    fi
  done
else
  echo "kimaki-config: persistent skill source dir not found at $SOURCE_DIR, skipping restore"
fi

echo "kimaki-config: done ($removed skills removed, $restored skills restored)"
