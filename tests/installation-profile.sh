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
INSTALL_CHAT=true
DRY_RUN=false
KIMAKI_BOT_TOKEN='must-not-be-persisted'
WP_CONTROL_TRANSPORT_JSON='["ssh","host","secret"]'
warn() { printf '%s\n' "$*" >&2; }
error() { printf '%s\n' "$*" >&2; return 1; }

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
grep -Eq '^plugin_candidates=.*data-machine-code' "$PROFILE"

SOURCE_MODE=""
RUNTIME=""
CHAT_BRIDGE=""
HOMEBOY_MODE=auto
INSTALL_CHAT=false
SOURCE_MODE_EXPLICIT=false
installation_profile_load
test "$SOURCE_MODE" = workspace
test "$RUNTIME" = opencode
test "$CHAT_BRIDGE" = kimaki
test "$HOMEBOY_MODE" = enabled
test "$INSTALL_CHAT" = true

# Explicit command-line intent remains authoritative over persisted defaults.
RUNTIME=codex
installation_profile_load
test "$RUNTIME" = codex

# Disabled optional components round-trip as intent rather than being inferred
# from whatever bridge binaries happen to be present during upgrade.
INSTALL_CHAT=false
CHAT_BRIDGE=kimaki
installation_profile_normalize "$INSTALLATION_OPERATION_SETUP"
installation_profile_write
INSTALL_CHAT=true
CHAT_BRIDGE=""
installation_profile_load
test "$INSTALL_CHAT" = false
test -z "$CHAT_BRIDGE"

# State paths never default to the filesystem root and never follow a symlink.
if (SITE_PATH="" EXISTING_WP="" installation_profile_file >/dev/null 2>&1); then
  echo "FAIL: missing site path resolved an installation profile" >&2
  exit 1
fi
rm -rf "$SITE_PATH/.wp-coding-agents"
mkdir "$TMP/outside"
printf 'sentinel\n' > "$TMP/outside/installation-profile"
ln -s "$TMP/outside" "$SITE_PATH/.wp-coding-agents"
installation_profile_write
test "$(cat "$TMP/outside/installation-profile")" = sentinel

echo "PASS: credential-free installation profile persists declarative intent"
