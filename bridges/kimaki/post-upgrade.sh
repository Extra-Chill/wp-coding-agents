#!/usr/bin/env bash
# post-upgrade.sh — Enforce kimaki skill + plugin state on every restart.
#
# Three symmetric passes run against the npm-installed kimaki package:
#   1. KILL    — remove unwanted bundled kimaki skills listed in
#                skills-kill-list.txt (target: $(npm root -g)/kimaki/skills/).
#   2. RESTORE skills  — re-copy wp-coding-agents skills from the persistent
#                source dir (kimaki-config/skills/) into kimaki/skills/.
#   3. RESTORE plugins — re-copy wp-coding-agents opencode plugins from the
#                persistent source dir (kimaki-config/plugins/) into
#                kimaki/plugins/. opencode.json references the plugin .ts
#                files at $(npm root -g)/kimaki/plugins/<file>.ts; without
#                this restore pass dm-context-filter.ts and dm-agent-sync.ts
#                silently disappear after every `npm update -g kimaki` and
#                Discord agents lose their context-filter / agent-sync
#                policies until the next manual upgrade.sh run.
#
# `npm update -g kimaki` wipes both kimaki/skills/ AND kimaki/plugins/, so
# the persistent kimaki-config/ dir is the source of truth and this script
# rehydrates the npm install on every kimaki restart.
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
# Plugins dir resolution priority (mirrors skills resolution):
#   1. KIMAKI_PLUGINS_DIR env var (explicit override)
#   2. $(npm root -g)/kimaki/plugins
#   3. /usr/lib/node_modules/kimaki/plugins (Linux VPS fallback when npm absent)
#
# Persistent skill source dir resolution priority:
#   1. KIMAKI_SKILL_SOURCE_DIR env var (explicit override)
#   2. $KIMAKI_DATA_DIR/kimaki-config/skills/ if KIMAKI_DATA_DIR set and dir exists
#   3. $HOME/.kimaki/kimaki-config/skills/ (local default)
#   4. /opt/kimaki-config/skills/ (VPS default)
#
# Persistent plugin source dir resolution priority (mirrors skill source):
#   1. KIMAKI_PLUGIN_SOURCE_DIR env var (explicit override)
#   2. $KIMAKI_DATA_DIR/kimaki-config/plugins/ if KIMAKI_DATA_DIR set and dir exists
#   3. $HOME/.kimaki/kimaki-config/plugins/ (local default)
#   4. /opt/kimaki-config/plugins/ (VPS default)
set -euo pipefail

# ----------------------------------------------------------------------------
# Resolve npm-installed kimaki paths.
# ----------------------------------------------------------------------------

if command -v npm &>/dev/null; then
  NPM_ROOT="$(npm root -g 2>/dev/null || true)"
else
  NPM_ROOT=""
fi

if [[ -n "${KIMAKI_SKILLS_DIR:-}" ]]; then
  SKILLS_DIR="$KIMAKI_SKILLS_DIR"
elif [[ -n "$NPM_ROOT" ]]; then
  SKILLS_DIR="$NPM_ROOT/kimaki/skills"
else
  SKILLS_DIR="/usr/lib/node_modules/kimaki/skills"
fi

if [[ -n "${KIMAKI_PLUGINS_DIR:-}" ]]; then
  PLUGINS_DIR="$KIMAKI_PLUGINS_DIR"
elif [[ -n "$NPM_ROOT" ]]; then
  PLUGINS_DIR="$NPM_ROOT/kimaki/plugins"
else
  PLUGINS_DIR="/usr/lib/node_modules/kimaki/plugins"
fi

KILL_LIST="$(dirname "$0")/skills-kill-list.txt"

# ----------------------------------------------------------------------------
# Pass 1: KILL — remove blacklisted bundled kimaki skills.
# ----------------------------------------------------------------------------

removed=0
if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "kimaki-config: skills dir not found at $SKILLS_DIR, skipping kill pass"
elif [[ ! -f "$KILL_LIST" ]]; then
  echo "kimaki-config: kill list not found at $KILL_LIST, skipping kill pass"
else
  while IFS= read -r skill || [[ -n "$skill" ]]; do
    # Skip comments and blank lines
    [[ -z "$skill" || "$skill" == \#* ]] && continue
    target="$SKILLS_DIR/$skill"
    if [[ -d "$target" ]]; then
      rm -rf "$target"
      echo "kimaki-config: removed skill $skill"
      removed=$((removed + 1))
    fi
  done < "$KILL_LIST"
fi

# ----------------------------------------------------------------------------
# Pass 2: RESTORE skills — re-copy wp-coding-agents skills from the
# persistent source dir into the npm-managed skills dir. Idempotent: `rm -rf`
# before each `cp -r` so a stale copy always gets replaced by the current
# source.
# ----------------------------------------------------------------------------

if [[ -n "${KIMAKI_SKILL_SOURCE_DIR:-}" ]]; then
  SKILL_SOURCE_DIR="$KIMAKI_SKILL_SOURCE_DIR"
elif [[ -n "${KIMAKI_DATA_DIR:-}" && -d "$KIMAKI_DATA_DIR/kimaki-config/skills" ]]; then
  SKILL_SOURCE_DIR="$KIMAKI_DATA_DIR/kimaki-config/skills"
elif [[ -d "$HOME/.kimaki/kimaki-config/skills" ]]; then
  SKILL_SOURCE_DIR="$HOME/.kimaki/kimaki-config/skills"
else
  SKILL_SOURCE_DIR="/opt/kimaki-config/skills"
fi

skills_restored=0
if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "kimaki-config: skills dir not found at $SKILLS_DIR, skipping skill restore"
elif [[ -d "$SKILL_SOURCE_DIR" ]]; then
  for skill_dir in "$SKILL_SOURCE_DIR"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    if [[ -f "$skill_dir/SKILL.md" ]]; then
      target="$SKILLS_DIR/$skill_name"
      rm -rf "$target"
      cp -r "$skill_dir" "$target"
      echo "kimaki-config: restored skill $skill_name"
      skills_restored=$((skills_restored + 1))
    fi
  done
else
  echo "kimaki-config: persistent skill source dir not found at $SKILL_SOURCE_DIR, skipping skill restore"
fi

# ----------------------------------------------------------------------------
# Pass 3: RESTORE plugins — re-copy wp-coding-agents opencode plugins from
# the persistent source dir into the npm-managed plugins dir.
#
# opencode.json references each plugin by absolute path at
# $(npm root -g)/kimaki/plugins/<file>.ts. The kimaki npm package does NOT
# ship a plugins/ dir, so this directory only ever exists because we put it
# there. `npm update -g kimaki` wipes it clean every time.
# ----------------------------------------------------------------------------

if [[ -n "${KIMAKI_PLUGIN_SOURCE_DIR:-}" ]]; then
  PLUGIN_SOURCE_DIR="$KIMAKI_PLUGIN_SOURCE_DIR"
elif [[ -n "${KIMAKI_DATA_DIR:-}" && -d "$KIMAKI_DATA_DIR/kimaki-config/plugins" ]]; then
  PLUGIN_SOURCE_DIR="$KIMAKI_DATA_DIR/kimaki-config/plugins"
elif [[ -d "$HOME/.kimaki/kimaki-config/plugins" ]]; then
  PLUGIN_SOURCE_DIR="$HOME/.kimaki/kimaki-config/plugins"
else
  PLUGIN_SOURCE_DIR="/opt/kimaki-config/plugins"
fi

plugins_restored=0
if [[ -d "$PLUGIN_SOURCE_DIR" ]]; then
  # Ensure the npm-managed plugins dir exists before copying.
  mkdir -p "$PLUGINS_DIR" 2>/dev/null || true
  if [[ ! -d "$PLUGINS_DIR" ]]; then
    echo "kimaki-config: could not create plugins dir at $PLUGINS_DIR, skipping plugin restore"
  else
    shopt -s nullglob
    for plugin_file in "$PLUGIN_SOURCE_DIR"/*.ts; do
      plugin_name="$(basename "$plugin_file")"
      target="$PLUGINS_DIR/$plugin_name"
      # Idempotent: only copy if missing or different. cmp returns 0 on match.
      if ! cmp -s "$plugin_file" "$target" 2>/dev/null; then
        cp "$plugin_file" "$target"
        echo "kimaki-config: restored plugin $plugin_name"
        plugins_restored=$((plugins_restored + 1))
      fi
    done
    shopt -u nullglob
  fi
else
  echo "kimaki-config: persistent plugin source dir not found at $PLUGIN_SOURCE_DIR, skipping plugin restore"
fi

echo "kimaki-config: done ($removed skills removed, $skills_restored skills restored, $plugins_restored plugins restored)"
