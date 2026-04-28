#!/usr/bin/env bash
# tests/post-upgrade-restore.sh — smoke test for bridges/kimaki/post-upgrade.sh
#
# Verifies the three passes (kill, restore skills, restore plugins) using
# temp-dir env overrides so the test never touches the real npm install or
# user config.
#
# What we cover:
#   1. Kill pass removes a blacklisted skill from the simulated skills dir.
#   2. Skill restore pass copies a SKILL.md tree from the persistent source
#      back into the (wiped) skills dir.
#   3. Plugin restore pass copies *.ts files from the persistent source into
#      the (wiped) plugins dir — the regression this script was added to fix.
#   4. Plugin restore is idempotent — running again does not re-copy files
#      that already match.
#   5. Plugin restore creates the live plugins dir if it does not exist
#      (the post-`npm update` reality).
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

# Simulated "npm-installed kimaki" layout — the targets the restore loop writes to.
LIVE_SKILLS="$TMP/npm/kimaki/skills"
LIVE_PLUGINS="$TMP/npm/kimaki/plugins"

# Persistent kimaki-config layout — the source of truth.
SRC_SKILLS="$TMP/config/skills"
SRC_PLUGINS="$TMP/config/plugins"

mkdir -p "$LIVE_SKILLS" "$SRC_SKILLS" "$SRC_PLUGINS"
# Note: deliberately NOT creating LIVE_PLUGINS — the script must mkdir it.

# Seed a blacklisted skill that the kill pass should remove.
mkdir -p "$LIVE_SKILLS/blacklisted-skill"
echo "stub" > "$LIVE_SKILLS/blacklisted-skill/SKILL.md"

# Seed a skill in the persistent source that should be restored.
mkdir -p "$SRC_SKILLS/restored-skill"
cat > "$SRC_SKILLS/restored-skill/SKILL.md" <<'EOF'
---
name: restored-skill
description: test fixture
---
body
EOF

# Seed two plugins in the persistent source that should be restored.
cat > "$SRC_PLUGINS/test-plugin-a.ts" <<'EOF'
// test-plugin-a.ts
export default async () => ({})
EOF
cat > "$SRC_PLUGINS/test-plugin-b.ts" <<'EOF'
// test-plugin-b.ts
export default async () => ({})
EOF

# Build a temp skills-kill-list.txt next to a copied post-upgrade.sh so the
# script's `dirname "$0"` lookup finds it.
TEST_SCRIPT_DIR="$TMP/kimaki-config-dir"
mkdir -p "$TEST_SCRIPT_DIR"
cp "$POST_UPGRADE" "$TEST_SCRIPT_DIR/post-upgrade.sh"
chmod +x "$TEST_SCRIPT_DIR/post-upgrade.sh"
cat > "$TEST_SCRIPT_DIR/skills-kill-list.txt" <<'EOF'
# test kill list
blacklisted-skill
EOF

# Run the script with explicit env overrides so it never touches the real
# npm install or user config.
KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_PLUGINS_DIR="$LIVE_PLUGINS" \
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

# Pass 1: kill pass removed the blacklisted skill.
assert_missing "$LIVE_SKILLS/blacklisted-skill"
assert_log_contains "removed skill blacklisted-skill"

# Pass 2: skill restore copied the SKILL.md tree.
assert_present "$LIVE_SKILLS/restored-skill/SKILL.md"
assert_log_contains "restored skill restored-skill"

# Pass 3: plugin restore created the dir AND copied both plugins.
assert_present "$LIVE_PLUGINS/test-plugin-a.ts"
assert_present "$LIVE_PLUGINS/test-plugin-b.ts"
assert_log_contains "restored plugin test-plugin-a.ts"
assert_log_contains "restored plugin test-plugin-b.ts"

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

# Wipe the live plugins dir to simulate `npm update -g kimaki` and confirm
# the next run rehydrates it from the persistent source — the actual fix.
rm -rf "$LIVE_PLUGINS"

KIMAKI_SKILLS_DIR="$LIVE_SKILLS" \
KIMAKI_PLUGINS_DIR="$LIVE_PLUGINS" \
KIMAKI_SKILL_SOURCE_DIR="$SRC_SKILLS" \
KIMAKI_PLUGIN_SOURCE_DIR="$SRC_PLUGINS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run3.log" 2>&1

if [[ ! -f "$LIVE_PLUGINS/test-plugin-a.ts" ]]; then
  echo "FAIL: plugins dir should be rehydrated after simulated npm update"
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
  "$FALLBACK_HOME/.kimaki/kimaki-config/skills/home-skill" \
  "$FALLBACK_HOME/.kimaki/kimaki-config/plugins" \
  "$FALLBACK_LIVE_SKILLS"
cat > "$FALLBACK_HOME/.kimaki/kimaki-config/skills/home-skill/SKILL.md" <<'EOF'
---
name: home-skill
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
KIMAKI_PLUGINS_DIR="$FALLBACK_LIVE_PLUGINS" \
  "$TEST_SCRIPT_DIR/post-upgrade.sh" > "$TMP/run4.log" 2>&1

if [[ ! -f "$FALLBACK_LIVE_SKILLS/home-skill/SKILL.md" ]]; then
  echo "FAIL: missing KIMAKI_DATA_DIR skills source should fall through to HOME source"
  cat "$TMP/run4.log"
  exit 1
fi
if [[ ! -f "$FALLBACK_LIVE_PLUGINS/home-plugin.ts" ]]; then
  echo "FAIL: missing KIMAKI_DATA_DIR plugins source should fall through to HOME source"
  cat "$TMP/run4.log"
  exit 1
fi
if ! grep -q "restored skill home-skill" "$TMP/run4.log"; then
  echo "FAIL: fallback run should restore the HOME-backed skill"
  cat "$TMP/run4.log"
  exit 1
fi
if ! grep -q "restored plugin home-plugin.ts" "$TMP/run4.log"; then
  echo "FAIL: fallback run should restore the HOME-backed plugin"
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

assert_log_contains_file "$TMP/missing.log" "WARNING: persistent plugin source dir not found at $MISSING_SRC; dm-context-filter.ts and dm-agent-sync.ts cannot be restored"
assert_log_contains_file "$TMP/missing.log" "WARNING: plugins dir not found at $MISSING_LIVE_PLUGINS; opencode.json plugin paths will be skipped by OpenCode"
assert_log_contains_file "$TMP/missing.log" "2 required plugins missing"

echo "PASS: tests/post-upgrade-restore.sh ($(grep -c '' "$TMP/run1.log" || true) lines run1, $(grep -c '' "$TMP/run3.log" || true) lines run3)"
