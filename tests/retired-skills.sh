#!/bin/bash
# tests/retired-skills.sh — copies of retired managed skills are removed from
# every detected runtime's skill dirs; other skills are never touched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/skills.sh"

log() { :; }
DRY_RUN=false
UPDATED_ITEMS=()
SITE_PATH="$TMP/site"
RUNTIME_PROJECT_ROOT="$SITE_PATH"
DETECTED_RUNTIMES=(opencode claude-code codex)
mkdir -p "$SITE_PATH"

roots="$(_retired_skill_roots)"
[ -n "$roots" ] || { echo "FAIL: no skill roots resolved"; exit 1; }
while IFS= read -r root; do
  mkdir -p "$root/upgrade-wp-coding-agents" "$root/wp-coding-agents-setup" "$root/operator-skill"
done <<< "$roots"

DRY_RUN=true
remove_retired_skills >/dev/null
while IFS= read -r root; do
  [ -d "$root/upgrade-wp-coding-agents" ] || { echo "FAIL: dry run removed $root/upgrade-wp-coding-agents"; exit 1; }
done <<< "$roots"

DRY_RUN=false
remove_retired_skills
while IFS= read -r root; do
  [ ! -e "$root/upgrade-wp-coding-agents" ] || { echo "FAIL: $root/upgrade-wp-coding-agents not removed"; exit 1; }
  [ ! -e "$root/wp-coding-agents-setup" ] || { echo "FAIL: $root/wp-coding-agents-setup not removed"; exit 1; }
  [ -d "$root/operator-skill" ] || { echo "FAIL: operator skill in $root was touched"; exit 1; }
done <<< "$roots"
[ "${#UPDATED_ITEMS[@]}" -gt 0 ] || { echo "FAIL: removal not reported"; exit 1; }

UPDATED_ITEMS=()
remove_retired_skills
[ "${#UPDATED_ITEMS[@]}" -eq 0 ] || { echo "FAIL: re-run reported changes"; exit 1; }

echo "PASS: tests/retired-skills.sh ($(wc -l <<< "$roots" | tr -d ' ') skill roots)"
