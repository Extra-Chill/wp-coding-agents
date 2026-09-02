#!/bin/bash
# Credential-free profile persistence is shared by setup and upgrade.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT_DIR/lib/desired-state-reconciler.sh"
source "$ROOT_DIR/lib/source-policy.sh"

SITE_PATH="$TMP/site"
WORKSPACE="$TMP/workspace repository"
mkdir -p "$SITE_PATH" "$WORKSPACE/subdirectory" "$TMP/not-a-repository"
git -C "$WORKSPACE" init -q
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
IS_STUDIO=true
SOURCE_MODE=workspace
RUNTIME=opencode
AGENT_SLUG=builder
CHAT_BRIDGE=kimaki
HOMEBOY_MODE=enabled
WORKSPACE_REPOSITORIES="$WORKSPACE"
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
grep -Eq '^plugin_candidates=data-machine wp-codebox$' "$PROFILE"
if grep -q 'data-machine-code\|DATAMACHINE_WORKSPACE_PATH' "$ROOT_DIR/lib/data-machine.sh"; then
  echo "FAIL: setup Data Machine phase still owns DMC installation state" >&2
  exit 1
fi
if grep -q 'discover_dm_workspace_dir\|wp datamachine-code' "$ROOT_DIR/setup.sh"; then
  echo "FAIL: setup still discovers a DMC workspace" >&2
  exit 1
fi

SOURCE_MODE=""
RUNTIME=""
AGENT_SLUG=""
CHAT_BRIDGE=""
HOMEBOY_MODE=auto
WORKSPACE_REPOSITORIES=""
INSTALL_CHAT=false
SOURCE_MODE_EXPLICIT=false
installation_profile_load
test "$SOURCE_MODE" = workspace
test "$RUNTIME" = opencode
test "$AGENT_SLUG" = builder
test "$CHAT_BRIDGE" = kimaki
test "$HOMEBOY_MODE" = enabled
test "$WORKSPACE_REPOSITORIES" = "$WORKSPACE"

WORKSPACE_REPOSITORIES=""
source_policy_add_workspace_repository "$WORKSPACE/subdirectory"
test "$WORKSPACE_REPOSITORIES" = "$WORKSPACE"
# The physical primary checkout root is canonical authority, so repeated flags
# and subdirectories cannot create duplicate runtime grants.
source_policy_add_workspace_repository "$WORKSPACE"
test "$WORKSPACE_REPOSITORIES" = "$WORKSPACE"
SOURCE_MODE=workspace
source_policy_validate_workspace_repositories
SOURCE_MODE=owned
if source_policy_validate_workspace_repositories; then
  echo "FAIL: owned mode accepted declared workspace repositories" >&2
  exit 1
fi
SOURCE_MODE=workspace
if source_policy_add_workspace_repository relative-repository; then
  echo "FAIL: relative workspace repository was accepted" >&2
  exit 1
fi
if source_policy_add_workspace_repository "$TMP/not-a-repository"; then
  echo "FAIL: non-Git workspace repository was accepted" >&2
  exit 1
fi
if source_policy_add_workspace_repository "$TMP/missing-repository"; then
  echo "FAIL: missing workspace repository was accepted" >&2
  exit 1
fi
test "$INSTALL_CHAT" = true

# Explicit command-line intent remains authoritative over persisted defaults.
RUNTIME=codex
AGENT_SLUG=reviewer
installation_profile_load
test "$RUNTIME" = codex
test "$AGENT_SLUG" = reviewer

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
