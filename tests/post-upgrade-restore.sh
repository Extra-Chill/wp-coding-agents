#!/usr/bin/env bash
# tests/post-upgrade-restore.sh — smoke test for bridges/kimaki/post-upgrade.sh
#
# Verifies the restore and verify passes using
# temp-dir env overrides so the test never touches the real npm install or
# user config.
#
# What we cover:
#   1. Bundled Kimaki skills are left untouched; filtering happens at startup.
#   2. Skill restore pass copies wp-coding-agents SKILL.md trees from the
#      persistent source back into the (wiped) skills dir.
#   3. Default plugin pass is a no-op because opencode loads the persistent
#      source dir directly.
#   4. Explicit KIMAKI_PLUGINS_DIR compatibility override still copies *.ts
#      files from the persistent source into the target dir.
#   5. Plugin restore is idempotent — running again does not re-copy files
#      that already match.
#   6. KIMAKI_DATA_DIR is only a hint: if its kimaki-config source dirs do
#      not exist, skills and plugins fall through to HOME/.kimaki/kimaki-config.
#
# Run from anywhere:
#   bash tests/post-upgrade-restore.sh
#
# Exit code: 0 on success, non-zero on first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POST_UPGRADE="$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh"

if [[ ! -x "$POST_UPGRADE" ]]; then
  echo "FAIL: $POST_UPGRADE is not executable"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Simulated "npm-installed kimaki" layout — the targets the skill restore loop
# and explicit plugin compatibility override write to.
LIVE_SKILLS="$TMP/npm/kimaki/skills"
LIVE_PLUGINS="$TMP/npm/kimaki/plugins"

# Persistent kimaki-config layout — the source of truth.
SRC_SKILLS="$TMP/config/skills"
SRC_PLUGINS="$TMP/config/plugins"

mkdir -p "$LIVE_SKILLS" "$SRC_SKILLS" "$SRC_PLUGINS"
# Note: deliberately NOT creating LIVE_PLUGINS — explicit override mode must
# still mkdir it.

# Seed bundled skills that post-upgrade must not remove. Managed Kimaki service
# startup now filters these with --disable-skill instead of mutating package
# directories.
mkdir -p "$LIVE_SKILLS/blacklisted-skill"
echo "stub" > "$LIVE_SKILLS/blacklisted-skill/SKILL.md"

# Seed a wp-coding-agents skill in the persistent source that should be restored.
mkdir -p "$SRC_SKILLS/upgrade-wp-coding-agents"
cat > "$SRC_SKILLS/upgrade-wp-coding-agents/SKILL.md" <<'EOF'
---
name: upgrade-wp-coding-agents
description: test fixture
---
body
EOF

mkdir -p "$SRC_SKILLS/unmanaged-skill"
cat > "$SRC_SKILLS/unmanaged-skill/SKILL.md" <<'EOF'
---
name: unmanaged-skill
description: unmanaged fixture
---
body
EOF

# Seed two required plugins in the persistent source. Default mode verifies them
# in place; explicit override mode restores them into the requested target.
cat > "$SRC_PLUGINS/dm-context-filter.ts" <<'EOF'
// dm-context-filter.ts
export default async () => ({})
EOF
cat > "$SRC_PLUGINS/dm-agent-sync.ts" <<'EOF'
// dm-agent-sync.ts
export default async () => ({})
EOF

TEST_SCRIPT_DIR="$TMP/kimaki-config-dir"
mkdir -p "$TEST_SCRIPT_DIR"
cp "$POST_UPGRADE" "$TEST_SCRIPT_DIR/post-upgrade.sh"
chmod +x "$TEST_SCRIPT_DIR/post-upgrade.sh"

# Run the script with explicit env overrides so it never touches the real
# npm install or user config.
KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_SKILL_SOURCE_DIR="$SRC_SKILLS" \
KIMAKI_PLUGIN_SOURCE_DIR="$SRC_PLUGINS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run1.log" 2>&1

assert_missing() {
  if [[ -e "$1" ]]; then
    echo "FAIL: $1 should not exist"
    cat "$TMP/run1.log"
    exit 1
  fi
}

assert_present() {
  if [[ ! -e "$1" ]]; then
    echo "FAIL: $1 should exist"
    cat "$TMP/run1.log"
    exit 1
  fi
}

assert_log_contains() {
  if ! grep -qF "$1" "$TMP/run1.log"; then
    echo "FAIL: log should contain: $1"
    cat "$TMP/run1.log"
    exit 1
  fi
}

assert_log_contains_file() {
  local file="$1"
  local needle="$2"
  if ! grep -qF "$needle" "$file"; then
    echo "FAIL: $file should contain: $needle"
    cat "$file"
    exit 1
  fi
}

# Pass 1: bundled Kimaki skills are not removed by post-upgrade.
assert_present "$LIVE_SKILLS/blacklisted-skill/SKILL.md"

# Pass 2: skill restore copied the allowed SKILL.md tree and skipped unmanaged skills.
assert_present "$LIVE_SKILLS/upgrade-wp-coding-agents/SKILL.md"
assert_log_contains "restored skill upgrade-wp-coding-agents"
assert_missing "$LIVE_SKILLS/unmanaged-skill/SKILL.md"
assert_log_contains "skipped unmanaged skill unmanaged-skill"

# Pass 3: default plugin restore is a no-op because opencode loads the
# persistent source directly.
assert_missing "$LIVE_PLUGINS"
assert_log_contains "plugin restore not needed; opencode loads persistent plugins at $SRC_PLUGINS"

# Explicit compatibility override still restores plugins into the requested dir.
KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_PLUGINS_DIR="$LIVE_PLUGINS" \
KIMAKI_SKILL_SOURCE_DIR="$SRC_SKILLS" \
KIMAKI_PLUGIN_SOURCE_DIR="$SRC_PLUGINS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run-override.log" 2>&1

assert_present "$LIVE_PLUGINS/dm-context-filter.ts"
assert_present "$LIVE_PLUGINS/dm-agent-sync.ts"
assert_log_contains_file "$TMP/run-override.log" "restored plugin dm-context-filter.ts"
assert_log_contains_file "$TMP/run-override.log" "restored plugin dm-agent-sync.ts"

# Idempotency: second run with the same state should restore zero plugins.
KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_PLUGINS_DIR="$LIVE_PLUGINS" \
KIMAKI_SKILL_SOURCE_DIR="$SRC_SKILLS" \
KIMAKI_PLUGIN_SOURCE_DIR="$SRC_PLUGINS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run2.log" 2>&1

if grep -q "restored plugin" "$TMP/run2.log"; then
  echo "FAIL: second run should not re-restore unchanged plugins"
  cat "$TMP/run2.log"
  exit 1
fi
if ! grep -q "0 plugins restored" "$TMP/run2.log"; then
  echo "FAIL: second run should report 0 plugins restored"
  cat "$TMP/run2.log"
  exit 1
fi

# Wipe the explicit target and confirm override mode can still rehydrate it.
rm -rf "$LIVE_PLUGINS"

KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_PLUGINS_DIR="$LIVE_PLUGINS" \
KIMAKI_SKILL_SOURCE_DIR="$SRC_SKILLS" \
KIMAKI_PLUGIN_SOURCE_DIR="$SRC_PLUGINS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run3.log" 2>&1

if [[ ! -f "$LIVE_PLUGINS/dm-context-filter.ts" ]]; then
  echo "FAIL: explicit plugins dir should be rehydrated after simulated npm update"
  cat "$TMP/run3.log"
  exit 1
fi
if ! grep -q "2 plugins restored" "$TMP/run3.log"; then
  echo "FAIL: rehydration run should report 2 plugins restored"
  cat "$TMP/run3.log"
  exit 1
fi

# Regression: KIMAKI_DATA_DIR may point at a real kimaki data dir that does not
# contain kimaki-config. In that case the derived paths must not short-circuit
# the source resolution chain; HOME/.kimaki/kimaki-config should still win.
FALLBACK_HOME="$TMP/fallback-home"
FALLBACK_DATA="$TMP/fallback-data"
FALLBACK_LIVE_SKILLS="$TMP/fallback-live/skills"
FALLBACK_LIVE_PLUGINS="$TMP/fallback-live/plugins"
mkdir -p \
  "$FALLBACK_DATA" \
  "$FALLBACK_HOME/.kimaki/kimaki-config/skills/upgrade-wp-coding-agents" \
  "$FALLBACK_HOME/.kimaki/kimaki-config/plugins" \
  "$FALLBACK_LIVE_SKILLS"
cat > "$FALLBACK_HOME/.kimaki/kimaki-config/skills/upgrade-wp-coding-agents/SKILL.md" <<'EOF'
---
name: upgrade-wp-coding-agents
description: fallback fixture
---
body
EOF
cat > "$FALLBACK_HOME/.kimaki/kimaki-config/plugins/home-plugin.ts" <<'EOF'
// home-plugin.ts
export default async () => ({})
EOF

HOME="$FALLBACK_HOME" \
KIMAKI_DATA_DIR="$FALLBACK_DATA" \
KIMAKI_SKILLS_DIR="$FALLBACK_LIVE_SKILLS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run4.log" 2>&1

if [[ ! -f "$FALLBACK_LIVE_SKILLS/upgrade-wp-coding-agents/SKILL.md" ]]; then
  echo "FAIL: missing KIMAKI_DATA_DIR skills source should fall through to HOME source"
  cat "$TMP/run4.log"
  exit 1
fi
if [[ -e "$FALLBACK_LIVE_PLUGINS" ]]; then
  echo "FAIL: default plugin verification should not create a separate live plugins dir"
  cat "$TMP/run4.log"
  exit 1
fi
if ! grep -q "restored skill upgrade-wp-coding-agents" "$TMP/run4.log"; then
  echo "FAIL: fallback run should restore the HOME-backed skill"
  cat "$TMP/run4.log"
  exit 1
fi
if ! grep -q "plugin restore not needed; opencode loads persistent plugins at $FALLBACK_HOME/.kimaki/kimaki-config/plugins" "$TMP/run4.log"; then
  echo "FAIL: fallback run should verify the HOME-backed plugin source in place"
  cat "$TMP/run4.log"
  exit 1
fi

# Missing persistent source + missing required live plugins must be loud. OpenCode
# silently skips absent plugin paths, so post-upgrade is the operator-facing signal.
MISSING_SRC="$TMP/missing-config/plugins"
MISSING_LIVE_PLUGINS="$TMP/missing-live/plugins"
KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_PLUGINS_DIR="$MISSING_LIVE_PLUGINS" \
KIMAKI_SKILL_SOURCE_DIR="$SRC_SKILLS" \
KIMAKI_PLUGIN_SOURCE_DIR="$MISSING_SRC" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/missing.log" 2>&1

assert_log_contains_file "$TMP/missing.log" "WARNING: persistent plugin source dir not found at $MISSING_SRC; dm-context-filter.ts and dm-agent-sync.ts cannot be loaded"
assert_log_contains_file "$TMP/missing.log" "WARNING: plugins dir not found at $MISSING_LIVE_PLUGINS; opencode.json plugin paths will be skipped by OpenCode"
assert_log_contains_file "$TMP/missing.log" "2 required plugins missing"

echo "PASS: tests/post-upgrade-restore.sh ($(grep -c '' "$TMP/run1.log" || true) lines run1, $(grep -c '' "$TMP/run3.log" || true) lines run3)"
