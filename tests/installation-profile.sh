#!/bin/bash
# Credential-free profile persistence is shared by setup and upgrade.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT_DIR/lib/desired-state-reconciler.sh"

SITE_PATH="$TMP/site"
mkdir -p "$SITE_PATH"
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
IS_STUDIO=true
SOURCE_MODE=workspace
RUNTIME=opencode
CHAT_BRIDGE=kimaki
HOMEBOY_MODE=enabled
DRY_RUN=false
KIMAKI_BOT_TOKEN='must-not-be-persisted'
WP_CONTROL_TRANSPORT_JSON='["ssh","host","secret"]'

installation_profile_normalize "$INSTALLATION_OPERATION_SETUP"
installation_profile_write

PROFILE="$(installation_profile_file)"
test -f "$PROFILE"
if stat -f '%Lp' "$PROFILE" >/dev/null 2>&1; then
  test "$(stat -f '%Lp' "$PROFILE")" = 600
else
  test "$(stat -c '%a' "$PROFILE")" = 600
fi
if grep -Eq 'TOKEN|TRANSPORT|secret|must-not-be-persisted' "$PROFILE"; then
  echo "FAIL: profile persisted credential or command transport material" >&2
  exit 1
fi

SOURCE_MODE=""
RUNTIME=""
CHAT_BRIDGE=""
HOMEBOY_MODE=auto
SOURCE_MODE_EXPLICIT=false
installation_profile_load
test "$SOURCE_MODE" = workspace
test "$RUNTIME" = opencode
test "$CHAT_BRIDGE" = kimaki
test "$HOMEBOY_MODE" = enabled

# Explicit command-line intent remains authoritative over persisted defaults.
RUNTIME=codex
installation_profile_load
test "$RUNTIME" = codex

echo "PASS: credential-free installation profile persists declarative intent"
