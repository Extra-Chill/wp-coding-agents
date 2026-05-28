#!/usr/bin/env bash
# post-upgrade.sh — Restore wp-coding-agents skills and validate plugin state.
#
# Two passes run against the npm-installed kimaki package and persistent
# kimaki-config directory:
#   1. RESTORE skills  — re-copy wp-coding-agents skills from the persistent
#                source dir (kimaki-config/skills/) into kimaki/skills/.
#   2. VERIFY plugins  — confirm required wp-coding-agents opencode plugins
#                exist at the persistent kimaki-config/plugins path loaded by
#                opencode.json. Local installs no longer restore plugins into
#                $(npm root -g)/kimaki/plugins because package-local files are
#                wiped by `npm update -g kimaki`.
#
# `npm update -g kimaki` still wipes kimaki/skills/, so skills are rehydrated
# from persistent kimaki-config/ on every restart. Plugins are loaded directly
# from persistent kimaki-config/plugins and only need validation here.
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
# Plugin target dir resolution priority:
#   1. KIMAKI_PLUGINS_DIR env var (explicit override)
#   2. Persistent plugin source dir below (default for local and VPS)
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

REQUIRED_PLUGINS=(dm-context-filter.ts dm-agent-sync.ts)
WP_CODING_AGENTS_SKILLS=(upgrade-wp-coding-agents wp-coding-agents-setup)

is_wp_coding_agents_skill() {
  local candidate="$1"
  local skill

  for skill in "${WP_CODING_AGENTS_SKILLS[@]}"; do
    [[ "$candidate" == "$skill" ]] && return 0
  done

  return 1
}

# ----------------------------------------------------------------------------
# Pass 1: RESTORE skills — re-copy wp-coding-agents skills from the
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
    if ! is_wp_coding_agents_skill "$skill_name"; then
      echo "kimaki-config: skipped unmanaged skill $skill_name"
      continue
    fi
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
# Pass 2: VERIFY plugins — opencode.json now loads wp-coding-agents plugins
# directly from persistent kimaki-config/plugins. When the target and source are
# the same directory (the default), there is nothing to restore. An explicit
# KIMAKI_PLUGINS_DIR override still receives a best-effort copy for operator
# controlled compatibility scenarios.
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
if [[ -n "${KIMAKI_PLUGINS_DIR:-}" ]]; then
  PLUGINS_DIR="$KIMAKI_PLUGINS_DIR"
else
  PLUGINS_DIR="$PLUGIN_SOURCE_DIR"
fi

if [[ -d "$PLUGIN_SOURCE_DIR" ]]; then
  if [[ "$PLUGINS_DIR" == "$PLUGIN_SOURCE_DIR" ]]; then
    echo "kimaki-config: plugin restore not needed; opencode loads persistent plugins at $PLUGIN_SOURCE_DIR"
  else
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
  fi
else
  echo "kimaki-config: WARNING: persistent plugin source dir not found at $PLUGIN_SOURCE_DIR; dm-context-filter.ts and dm-agent-sync.ts cannot be loaded"
fi

missing_required_plugins=0
if [[ ! -d "$PLUGINS_DIR" ]]; then
  echo "kimaki-config: WARNING: plugins dir not found at $PLUGINS_DIR; opencode.json plugin paths will be skipped by OpenCode"
  missing_required_plugins=${#REQUIRED_PLUGINS[@]}
else
  for required_plugin in "${REQUIRED_PLUGINS[@]}"; do
    if [[ ! -f "$PLUGINS_DIR/$required_plugin" ]]; then
      echo "kimaki-config: WARNING: required OpenCode plugin missing at $PLUGINS_DIR/$required_plugin; opencode.json references will be silently skipped"
      missing_required_plugins=$((missing_required_plugins + 1))
    fi
  done
fi

echo "kimaki-config: done ($skills_restored skills restored, $plugins_restored plugins restored, $missing_required_plugins required plugins missing)"
