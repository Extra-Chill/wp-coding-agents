#!/bin/bash
# Regression coverage for canonical managed skill targets (#306).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/skills.sh"

DRY_RUN=false
INSTALL_SKILLS=true
CHAT_BRIDGE=""
LOCAL_MODE=true
FAILED=0

log() { :; }

assert_present() {
  if [ -e "$1" ]; then
    echo "  ok   $2"
  else
    echo "  FAIL $2 (missing: $1)"
    FAILED=$((FAILED + 1))
  fi
}

assert_missing() {
  if [ ! -e "$1" ]; then
    echo "  ok   $2"
  else
    echo "  FAIL $2 (unexpected: $1)"
    FAILED=$((FAILED + 1))
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    echo "  ok   $3"
  else
    echo "  FAIL $3 (expected: $2, actual: $1)"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) echo "  ok   $3" ;;
    *)
      echo "  FAIL $3 (missing text: $2)"
      FAILED=$((FAILED + 1))
      ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*)
      echo "  FAIL $3 (unexpected text: $2)"
      FAILED=$((FAILED + 1))
      ;;
    *) echo "  ok   $3" ;;
  esac
}

seed_root() {
  local root="$1"
  mkdir -p "$root/upgrade-wp-coding-agents" "$root/wp-coding-agents-setup" "$root/user-skill"
  printf 'old\n' > "$root/upgrade-wp-coding-agents/SKILL.md"
  printf 'retired\n' > "$root/wp-coding-agents-setup/SKILL.md"
  printf 'user\n' > "$root/user-skill/SKILL.md"
}

run_case() {
  SITE_PATH="$TMP/$1"
  RUNTIME="$2"
  shift 2
  DETECTED_RUNTIMES=("$@")
  mkdir -p "$SITE_PATH"
  install_skills
}

echo "==> OpenCode only"
run_case opencode opencode opencode
assert_present "$SITE_PATH/.opencode/skills/upgrade-wp-coding-agents/SKILL.md" "uses .opencode/skills"
assert_missing "$SITE_PATH/.claude/skills/upgrade-wp-coding-agents" "does not create Claude target"

echo "==> Codex only"
run_case codex codex codex
assert_present "$SITE_PATH/.agents/skills/upgrade-wp-coding-agents/SKILL.md" "uses .agents/skills"
assert_missing "$SITE_PATH/.claude/skills/upgrade-wp-coding-agents" "does not create Claude target"

echo "==> Claude Code only"
run_case claude claude-code claude-code
assert_present "$SITE_PATH/.claude/skills/upgrade-wp-coding-agents/SKILL.md" "uses .claude/skills"
assert_missing "$SITE_PATH/.opencode/skills/upgrade-wp-coding-agents" "does not create OpenCode target"

echo "==> Claude Code, Codex, and OpenCode overlap cleanup and preservation"
SITE_PATH="$TMP/overlap"
seed_root "$SITE_PATH/.claude/skills"
seed_root "$SITE_PATH/.opencode/skills"
seed_root "$SITE_PATH/.agents/skills"
RUNTIME=claude-code
DETECTED_RUNTIMES=(claude-code opencode codex)
install_skills
assert_present "$SITE_PATH/.claude/skills/upgrade-wp-coding-agents/SKILL.md" "keeps canonical Claude copy"
assert_eq "$SKILLS_DIR" "$SITE_PATH/.claude/skills" "reports the canonical target"
assert_missing "$SITE_PATH/.opencode/skills/upgrade-wp-coding-agents" "removes noncanonical OpenCode copy"
assert_missing "$SITE_PATH/.agents/skills/upgrade-wp-coding-agents" "removes noncanonical Codex copy"
assert_missing "$SITE_PATH/.claude/skills/wp-coding-agents-setup" "removes retired Claude copy"
assert_missing "$SITE_PATH/.opencode/skills/wp-coding-agents-setup" "removes retired OpenCode copy"
assert_missing "$SITE_PATH/.agents/skills/wp-coding-agents-setup" "removes retired Codex copy"
assert_present "$SITE_PATH/.claude/skills/user-skill/SKILL.md" "preserves Claude user skill"
assert_present "$SITE_PATH/.opencode/skills/user-skill/SKILL.md" "preserves OpenCode user skill"
assert_present "$SITE_PATH/.agents/skills/user-skill/SKILL.md" "preserves Codex user skill"
SUMMARY_OUTPUT="$(log() { printf '%s\n' "$1"; }; print_skills_summary)"
assert_contains "$SUMMARY_OUTPUT" "$SITE_PATH/.claude/skills/" "summary reports canonical Claude target"
assert_not_contains "$SUMMARY_OUTPUT" "$SITE_PATH/.opencode/skills/" "summary omits noncanonical OpenCode target"
assert_not_contains "$SUMMARY_OUTPUT" "$SITE_PATH/.agents/skills/" "summary omits noncanonical Codex target"

echo "==> overlap install is idempotent"
install_skills
assert_present "$SITE_PATH/.claude/skills/upgrade-wp-coding-agents/SKILL.md" "canonical copy remains after rerun"
assert_missing "$SITE_PATH/.opencode/skills/upgrade-wp-coding-agents" "duplicate remains absent after rerun"
assert_missing "$SITE_PATH/.agents/skills/upgrade-wp-coding-agents" "Codex duplicate remains absent after rerun"
assert_present "$SITE_PATH/.opencode/skills/user-skill/SKILL.md" "user skill remains after rerun"
assert_present "$SITE_PATH/.agents/skills/user-skill/SKILL.md" "Codex user skill remains after rerun"

echo "==> dry run preserves managed directories"
seed_root "$SITE_PATH/.opencode/skills"
seed_root "$SITE_PATH/.agents/skills"
DRY_RUN=true
install_skills >/dev/null
DRY_RUN=false
assert_present "$SITE_PATH/.opencode/skills/upgrade-wp-coding-agents/SKILL.md" "dry run preserves duplicate"
assert_present "$SITE_PATH/.opencode/skills/wp-coding-agents-setup/SKILL.md" "dry run preserves retired skill"
assert_present "$SITE_PATH/.agents/skills/upgrade-wp-coding-agents/SKILL.md" "dry run preserves Codex duplicate"
assert_present "$SITE_PATH/.agents/skills/wp-coding-agents-setup/SKILL.md" "dry run preserves Codex retired skill"

echo "==> explicit runtime narrowing"
SITE_PATH="$TMP/narrowed"
seed_root "$SITE_PATH/.claude/skills"
seed_root "$SITE_PATH/.opencode/skills"
RUNTIME=opencode
DETECTED_RUNTIMES=(opencode)
install_skills
assert_present "$SITE_PATH/.opencode/skills/upgrade-wp-coding-agents/SKILL.md" "explicit OpenCode uses OpenCode target"
assert_missing "$SITE_PATH/.opencode/skills/wp-coding-agents-setup" "cleans scoped retired skill"
assert_present "$SITE_PATH/.claude/skills/wp-coding-agents-setup/SKILL.md" "does not clean unscoped Claude root"
assert_present "$SITE_PATH/.claude/skills/upgrade-wp-coding-agents/SKILL.md" "does not alter unscoped Claude copy"

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: managed skill target regressions passed"
