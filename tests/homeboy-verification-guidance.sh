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
wp_cli_transport_set studio wp
SITE_PATH=""
STUDIO_SUMMARY="$(print_homeboy_verification_commands)"
SETUP_VERIFY="operator-entrypoints/wp-coding-agents-setup/verify.md"

assert_contract_command() {
  local command="$1" file

  case "$SUMMARY" in
    *"$command"*) ;;
    *) echo "FAIL: generated summary is missing: $command"; exit 1 ;;
  esac

  for file in "$SETUP_VERIFY"; do
    if ! grep -qF -- "$command" "$file"; then
      echo "FAIL: $file is missing generated summary command: $command"
      exit 1
    fi
  done
}

assert_contract_command "homeboy --version"
assert_contract_command "homeboy extension list"
assert_contract_command "homeboy extension show wordpress --live-readiness"
assert_contract_command "homeboy config show --format=json | jq -e '.data.config.worktree_providers.dmc == null and .data.config.settings.worktree_provider_lifecycle.dmc == null'"
assert_contract_command "homeboy project show <project-id>"
assert_contract_command "homeboy project components list <project-id>"
assert_contract_command "wp datamachine memory compose AGENTS.md --path=/path/to/site"

for command in \
  "studio wp datamachine memory compose AGENTS.md"; do
  case "$STUDIO_SUMMARY" in
    *"$command"*) ;;
    *) echo "FAIL: generated Studio summary is missing: $command"; exit 1 ;;
  esac
  for file in "$SETUP_VERIFY"; do
    if ! grep -qF -- "$command" "$file"; then
      echo "FAIL: $file is missing generated Studio summary command: $command"
      exit 1
    fi
  done
done

echo "OK: Homeboy verification guidance matches the generated runtime summary"

# Metadata can say ready while the live dependency probe fails. Exercise the
# real reconciliation predicate with the CLI's current command envelopes.
homeboy_bin() { printf '%s' homeboy; }
homeboy_run() {
  case "$*" in
    'extension show wordpress --live-readiness')
      printf '%s' "$READINESS_RESPONSE"
      return "$READINESS_EXIT_CODE"
      ;;
    'extension list')
      printf '%s' '{"success":true,"data":{"extensions":[{"id":"wordpress","ready":true}]}}'
      ;;
    *) return 1 ;;
  esac
}

READINESS_EXIT_CODE=0
READINESS_RESPONSE='{"success":true,"data":{"extension":{"id":"wordpress","ready":true}}}'
homeboy_wordpress_extension_ready || { printf '%s\n' 'FAIL: live ready extension was rejected'; exit 1; }

assert_not_ready() {
  READINESS_RESPONSE="$1"
  if homeboy_wordpress_extension_ready; then
    printf '%s\n' 'FAIL: reconciliation accepted non-ready live evidence'
    exit 1
  fi
}

assert_not_ready '{"success":true,"data":{"extension":{"id":"wordpress","ready":false}}}'
assert_not_ready '{"success":true,"data":{"extension":{"id":"wordpress","ready":null,"readiness":"unknown"}}}'
assert_not_ready '{"success":true,"data":{"extension":{"id":"other","ready":true}}}'
assert_not_ready '{"success":false,"data":{"extension":{"id":"wordpress","ready":true}}}'
assert_not_ready '{"success":true,"data":{"extension":{"id":"wordpress","ready":true,"compatible":false}}}'
assert_not_ready '{"success":true,"data":{}}'
assert_not_ready 'invalid JSON'
READINESS_EXIT_CODE=1
assert_not_ready '{"success":true,"data":{"extension":{"id":"wordpress","ready":true}}}'
printf '%s\n' 'OK: readiness uses live CLI evidence and rejects stale metadata, unknown status and failures'
