#!/usr/bin/env bash
# post-upgrade.sh — Enforce the managed Kimaki skill surface and validate plugin state.
#
# Two passes run against the npm-installed kimaki package and persistent
# kimaki-config directory:
#   1. SKILL surface   — remove package-local managed skill duplicates and,
#                when a skills-enable-list.txt is present, remove bundled skills
#                outside the allowlist from kimaki/skills/.
#   2. PATCH prompt    — replace Kimaki's package-generated system prompt on
#                managed installs before it reaches OpenCode's per-call system
#                field. OpenCode plugin transforms are still kept as defense in
#                depth, but cannot be the only boundary for this prompt surface.
#   3. VERIFY plugins  — confirm required wp-coding-agents opencode plugins
#                exist at the persistent kimaki-config/plugins path loaded by
#                opencode.json. Local installs no longer restore plugins into
#                $(npm root -g)/kimaki/plugins because package-local files are
#                wiped by `npm update -g kimaki`.
#
# `npm update -g kimaki` can recreate bundled skills in kimaki/skills/. The
# managed service starts Kimaki with --enable-skill, but post-upgrade also
# enforces the package-local skill surface so recreated bundled skills and stale
# wp-coding-agents duplicates do not leak or trigger duplicate discovery.
# Plugins are loaded directly from persistent kimaki-config/plugins and only
# need validation here.
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
# Persistent config dir resolution priority:
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
WP_CODING_AGENTS_SKILLS=(upgrade-wp-coding-agents)

if [[ -n "${KIMAKI_DIST_DIR:-}" ]]; then
  KIMAKI_DIST_DIR_RESOLVED="$KIMAKI_DIST_DIR"
elif [[ -n "$NPM_ROOT" ]]; then
  KIMAKI_DIST_DIR_RESOLVED="$NPM_ROOT/kimaki/dist"
else
  KIMAKI_DIST_DIR_RESOLVED="/usr/lib/node_modules/kimaki/dist"
fi

is_wp_coding_agents_skill() {
  local candidate="$1"
  local skill

  for skill in "${WP_CODING_AGENTS_SKILLS[@]}"; do
    [[ "$candidate" == "$skill" ]] && return 0
  done

  return 1
}

# ----------------------------------------------------------------------------
# Pass 1: SKILL surface — keep persistent kimaki-config/skills/ as the durable
# source and avoid copying it into Kimaki's package skills dir. OpenCode already
# discovers project/user/runtime skills; package-local copies only create
# duplicate skill warnings. If an allowlist exists, remove package-local skills
# outside it so npm upgrades/restarts cannot recreate unwanted bundled skills
# such as critique.
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

if [[ -n "${KIMAKI_SKILL_ENABLES_FILE:-}" ]]; then
  SKILL_ENABLES_FILE="$KIMAKI_SKILL_ENABLES_FILE"
elif [[ -n "${KIMAKI_DATA_DIR:-}" && -f "$KIMAKI_DATA_DIR/kimaki-config/skills-enable-list.txt" ]]; then
  SKILL_ENABLES_FILE="$KIMAKI_DATA_DIR/kimaki-config/skills-enable-list.txt"
elif [[ -f "$HOME/.kimaki/kimaki-config/skills-enable-list.txt" ]]; then
  SKILL_ENABLES_FILE="$HOME/.kimaki/kimaki-config/skills-enable-list.txt"
elif [[ -f "/opt/kimaki-config/skills-enable-list.txt" ]]; then
  SKILL_ENABLES_FILE="/opt/kimaki-config/skills-enable-list.txt"
else
  SKILL_ENABLES_FILE=""
fi

skill_is_enabled() {
  local candidate="$1"
  [[ -n "$SKILL_ENABLES_FILE" && -f "$SKILL_ENABLES_FILE" ]] || return 1
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    [[ "$line" == "$candidate" ]] && return 0
  done < "$SKILL_ENABLES_FILE"
  return 1
}

skills_removed=0
skills_unremovable=0

# Best-effort removal inside the npm package directory.
#
# This script runs as ExecStartPre, as the SERVICE user, with `set -e` and no
# `-` prefix on the unit directive — so any non-zero exit here blocks the
# service from starting at all. The package dir is root-owned
# (/usr/lib/node_modules/kimaki, 0755), which a non-root service user cannot
# unlink from. An unguarded `rm -rf` therefore turns a supported install shape
# into a service that will not boot, and it fails LATE: only once `npm update -g
# kimaki` has recreated a bundled skill is there anything to remove.
#
# These removals are hygiene against npm restoring files we do not want on the
# skill surface, not correctness. Not being able to perform them is worth a
# warning, never a failed start.
try_remove_package_path() {
  local path="$1" label="$2"
  if rm -rf "$path" 2>/dev/null; then
    echo "kimaki-config: removed $label"
    skills_removed=$((skills_removed + 1))
    return 0
  fi
  echo "kimaki-config: WARNING: could not remove $label at $path (owned by another user?); leaving it in place"
  skills_unremovable=$((skills_unremovable + 1))
  return 0
}

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "kimaki-config: skills dir not found at $SKILLS_DIR, skipping package skill surface enforcement"
else
  for skill_dir in "$SKILLS_DIR"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    if is_wp_coding_agents_skill "$skill_name"; then
      try_remove_package_path "$skill_dir" "package-local duplicate skill $skill_name"
      continue
    fi

    if [[ -n "$SKILL_ENABLES_FILE" && -f "$SKILL_ENABLES_FILE" ]] && ! skill_is_enabled "$skill_name"; then
      try_remove_package_path "$skill_dir" "package-local skill outside allowlist $skill_name"
    fi
  done
fi

if [[ -d "$SKILL_SOURCE_DIR" ]]; then
  echo "kimaki-config: persistent skill source available at $SKILL_SOURCE_DIR"
else
  echo "kimaki-config: persistent skill source dir not found at $SKILL_SOURCE_DIR"
fi

# ----------------------------------------------------------------------------
# Pass 2: PATCH prompt — Kimaki passes its generated Discord guidance through
# session.promptAsync({ system: ... }). Current OpenCode plugin transforms do not
# reliably rewrite that SDK per-call system field before model dispatch. Patch
# the managed Kimaki package entrypoint directly so the bulky generic prompt is
# never submitted on wp-coding-agents managed installs.
# ----------------------------------------------------------------------------

prompt_patch_status="skipped"
_kimaki_patch_system_prompt() {
  local system_message_file="$KIMAKI_DIST_DIR_RESOLVED/system-message.js"

  if [[ ! -f "$system_message_file" ]]; then
    echo "kimaki-config: WARNING: Kimaki system-message.js not found at $system_message_file; managed prompt patch skipped"
    prompt_patch_status="missing"
    return 0
  fi

  SYSTEM_MESSAGE_FILE="$system_message_file" node <<'NODE'
const fs = require('node:fs')

const file = process.env.SYSTEM_MESSAGE_FILE
const marker = 'wp-coding-agents managed Kimaki system prompt patch'
const literalDollar = '$'
const source = fs.readFileSync(file, 'utf8')

if (source.includes(marker)) {
  process.exit(0)
}

const signature = /^export function getOpencodeSystemMessage\(\{[^\n]*\}\) \{\n/m
const match = source.match(signature)
const managedReturn = `${match?.[0] ?? ''}    // ${marker}. Keep this small; Data Machine AGENTS.md owns managed runtime policy.
    return \`## Kimaki Discord Bridge

Kimaki connects this OpenCode session to Discord. Treat Discord as the human coordination surface: keep the thread updated, ask the user for files with the native upload tool when needed, upload user-facing artifacts when useful, mention users by Discord ID when action is required, and archive the thread when the user explicitly asks.

## Managed Coding Runtime

Use the composed Data Machine AGENTS.md guidance for the coding runtime, workspace, orchestration, preview, tunnel, and evidence capabilities available on this install.

## Bridge Diagnostics

For Kimaki bridge failures, inspect \\${literalDollar}HOME/.kimaki/kimaki.log. The log is reset every time Kimaki restarts, so it only covers the current run.
\`;
`

if (!match) {
  console.error(`function signature not found in ${file}`)
  process.exit(2)
}

fs.writeFileSync(file, source.replace(signature, managedReturn), 'utf8')
NODE
  local patch_exit=$?
  if [[ "$patch_exit" -eq 0 ]]; then
    echo "kimaki-config: managed Kimaki system prompt patch active at $system_message_file"
    prompt_patch_status="active"
  else
    echo "kimaki-config: WARNING: managed Kimaki system prompt patch failed for $system_message_file"
    prompt_patch_status="failed"
  fi
}

_kimaki_patch_system_prompt

# ----------------------------------------------------------------------------
# Pass 3: VERIFY plugins — opencode.json now loads wp-coding-agents plugins
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

# Removed in wp-coding-agents#300. Scrub managed copies from both the durable
# source and compatibility target during upgrades, including local and service installs.
for obsolete_dir in "$PLUGIN_SOURCE_DIR" "$PLUGINS_DIR"; do
  obsolete_plugin="$obsolete_dir/homeboy-notification-context.ts"
  if [[ -e "$obsolete_plugin" ]]; then
    # Same reasoning as try_remove_package_path: on a VPS PLUGINS_DIR is
    # /opt/kimaki-config/plugins, which is root-owned, and this runs as the
    # service user during ExecStartPre.
    if rm -f "$obsolete_plugin" 2>/dev/null; then
      echo "kimaki-config: removed obsolete plugin $obsolete_plugin"
    else
      echo "kimaki-config: WARNING: could not remove obsolete plugin $obsolete_plugin (owned by another user?)"
    fi
  fi
done

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
  echo "kimaki-config: WARNING: persistent plugin source dir not found at $PLUGIN_SOURCE_DIR; managed OpenCode plugins cannot be loaded"
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

echo "kimaki-config: done ($skills_removed package skills removed, prompt patch $prompt_patch_status, $plugins_restored plugins restored, $missing_required_plugins required plugins missing)"
