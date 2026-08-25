#!/bin/bash
# Keep generated Homeboy summary commands and operator guidance on one contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"

WP_CMD="wp"
SITE_PATH="/path/to/site"
WP_ROOT_FLAG=""

SUMMARY="$(print_homeboy_verification_commands)"
WP_CMD="studio wp"
SITE_PATH=""
STUDIO_SUMMARY="$(print_homeboy_verification_commands)"
SKILL="skills/upgrade-wp-coding-agents/SKILL.md"
SETUP_VERIFY="operator-entrypoints/wp-coding-agents-setup/verify.md"

assert_contract_command() {
  local command="$1" file

  case "$SUMMARY" in
    *"$command"*) ;;
    *) echo "FAIL: generated summary is missing: $command"; exit 1 ;;
  esac

  for file in "$SKILL" "$SETUP_VERIFY"; do
    if ! grep -qF -- "$command" "$file"; then
      echo "FAIL: $file is missing generated summary command: $command"
      exit 1
    fi
  done
}

assert_contract_command "homeboy --version"
assert_contract_command "homeboy extension list"
assert_contract_command "homeboy extension show wordpress"
assert_contract_command "homeboy config show /worktree_providers/dmc"
assert_contract_command "homeboy project show <project-id>"
assert_contract_command "homeboy project components list <project-id>"
assert_contract_command "wp datamachine-code workspace worktree provider --format=json --path=/path/to/site"
assert_contract_command "wp datamachine memory compose AGENTS.md --path=/path/to/site"

for command in \
  "studio wp datamachine-code workspace worktree provider --format=json" \
  "studio wp datamachine memory compose AGENTS.md"; do
  case "$STUDIO_SUMMARY" in
    *"$command"*) ;;
    *) echo "FAIL: generated Studio summary is missing: $command"; exit 1 ;;
  esac
  for file in "$SKILL" "$SETUP_VERIFY"; do
    if ! grep -qF -- "$command" "$file"; then
      echo "FAIL: $file is missing generated Studio summary command: $command"
      exit 1
    fi
  done
done

for file in "$SKILL" "$SETUP_VERIFY"; do
  if grep -qF -- "option get datamachine_code_homeboy_available" "$file"; then
    echo "FAIL: $file still probes optional legacy Homeboy state"
    exit 1
  fi
done

case "$SUMMARY" in
  *"option get datamachine_code_homeboy_available"*)
    echo "FAIL: generated summary probes optional legacy Homeboy state"
    exit 1
    ;;
esac

echo "OK: Homeboy verification guidance matches the generated runtime summary"
