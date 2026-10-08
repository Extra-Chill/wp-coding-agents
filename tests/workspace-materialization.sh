#!/bin/bash
# Primary repository materialization is host setup state, never WordPress state.
set -eu

ROOT_SCOPE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
scope_phase="$(sed -n '/^source_policy_resolve_mode$/,/^source_policy_resolve_owned_sources$/p' "$ROOT_SCOPE/upgrade.sh")"
source_policy_resolve_mode() { :; }
source_policy_resolve_owned_sources() { :; }
source_policy_materialize_workspace_repositories() { scope_calls="${scope_calls}materialize "; }
source_policy_validate_workspace_repositories() { scope_calls="${scope_calls}validate "; }
for selected in ROADIE_ONLY PLUGINS_ONLY SKILLS_ONLY AGENTS_MD_ONLY RECONCILE_SERVICES_ONLY full; do
  ROADIE_ONLY=false PLUGINS_ONLY=false SKILLS_ONLY=false AGENTS_MD_ONLY=false RECONCILE_SERVICES_ONLY=false
  if [ "$selected" != full ]; then printf -v "$selected" '%s' true; fi
  scope_calls=""
  eval "$scope_phase"
  if [ "$selected" = full ]; then
    test "$scope_calls" = 'materialize validate ' || exit 1
  else
    test -z "$scope_calls" || { printf 'FAIL: %s crossed into repository provisioning\n' "$selected" >&2; exit 1; }
  fi
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT/lib/common.sh"
source "$ROOT/lib/source-policy.sh"
source "$ROOT/lib/desired-state-reconciler.sh"

ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
SITE_PATH="$TMP/site"
DESTINATION="$TMP/workspace/materialized repository"
mkdir -p "$SEED" "$SITE_PATH"
git -C "$SEED" init -q
git -C "$SEED" config user.email fixture@example.test
git -C "$SEED" config user.name Fixture
printf 'materialized\n' > "$SEED/plugin.php"
git -C "$SEED" add plugin.php
git -C "$SEED" commit -qm initial
git clone -q --bare "$SEED" "$ORIGIN"

SOURCE_MODE=workspace
WORKSPACE_REPOSITORIES=""
WORKSPACE_REPOSITORY_CLONES=""
WORKSPACE_REPOSITORIES_EXPLICIT=false
WORKSPACE_REPOSITORY_CLONES_EXPLICIT=false
DRY_RUN=false
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
IS_STUDIO=false
RUNTIME=opencode
INSTALL_CHAT=false
CHAT_BRIDGE=""
HOMEBOY_MODE=disabled
DETECTED_RUNTIMES=(opencode)

source_policy_add_workspace_repository_clone "$ORIGIN" "$DESTINATION"
source_policy_materialize_workspace_repositories
test -f "$DESTINATION/plugin.php"
CANONICAL_DESTINATION="$(cd "$DESTINATION" && pwd -P)"
test "$(git -C "$DESTINATION" rev-parse --show-toplevel)" = "$CANONICAL_DESTINATION"
test "$(source_policy_workspace_repositories)" = "$DESTINATION"
source_policy_materialize_workspace_repositories

installation_profile_normalize "$INSTALLATION_OPERATION_SETUP"
installation_profile_write
PROFILE="$(installation_profile_file)"
grep -q '^workspace_repository_clones=' "$PROFILE"
if grep -q "$ORIGIN" "$PROFILE"; then
  echo "FAIL: clone declaration was not encoded" >&2
  exit 1
fi

WORKSPACE_REPOSITORIES=""
WORKSPACE_REPOSITORY_CLONES=""
WORKSPACE_REPOSITORY_CLONES_EXPLICIT=false
SOURCE_MODE_EXPLICIT=false
installation_profile_load
test "$WORKSPACE_REPOSITORIES" = "$DESTINATION"
case "$WORKSPACE_REPOSITORY_CLONES" in
  "$ORIGIN"$'\t'"$DESTINATION") ;;
  *) echo "FAIL: clone declaration did not round-trip" >&2; exit 1 ;;
esac

rm -rf "$DESTINATION"
source_policy_materialize_workspace_repositories
test -f "$DESTINATION/plugin.php"

git -C "$DESTINATION" config remote.origin.url "$TMP/wrong-origin.git"
if bash -c 'source "$1/lib/common.sh"; source "$1/lib/source-policy.sh"; SOURCE_MODE=workspace; WORKSPACE_REPOSITORY_CLONES="$2"$'\''\t'\''"$3"; source_policy_materialize_workspace_repositories' _ "$ROOT" "$ORIGIN" "$DESTINATION" >/dev/null 2>&1; then
  echo "FAIL: existing checkout with the wrong origin was accepted" >&2
  exit 1
fi
git -C "$DESTINATION" config remote.origin.url "$ORIGIN"

source_policy_begin_workspace_repository_declarations
source_policy_add_workspace_repository "$SEED"
installation_profile_load
test -z "$WORKSPACE_REPOSITORY_CLONES"
test "$WORKSPACE_REPOSITORIES" = "$(cd "$SEED" && pwd -P)"

WORKSPACE_REPOSITORIES=""
WORKSPACE_REPOSITORY_CLONES="$ORIGIN"$'\t'"$DESTINATION"
WORKSPACE_REPOSITORIES_EXPLICIT=false

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"
printf 'preserve\n' > "$DESTINATION/sentinel"
if bash -c 'source "$1/lib/common.sh"; source "$1/lib/source-policy.sh"; SOURCE_MODE=workspace; WORKSPACE_REPOSITORY_CLONES="$2"$'\''\t'\''"$3"; source_policy_materialize_workspace_repositories' _ "$ROOT" "$ORIGIN" "$DESTINATION" >/dev/null 2>&1; then
  echo "FAIL: existing non-Git destination was overwritten" >&2
  exit 1
fi
test "$(cat "$DESTINATION/sentinel")" = preserve

WORKSPACE_REPOSITORIES=""
WORKSPACE_REPOSITORY_CLONES=""
if bash -c 'source "$1/lib/common.sh"; source "$1/lib/source-policy.sh"; source_policy_add_workspace_repository_clone "$2" "$3"' _ "$ROOT" 'https://token@example.com/repo.git' "$TMP/credential-target" >/dev/null 2>&1; then
  echo "FAIL: credential-bearing remote was accepted" >&2
  exit 1
fi
if bash -c 'source "$1/lib/common.sh"; source "$1/lib/source-policy.sh"; source_policy_add_workspace_repository_clone "$2" "$3"' _ "$ROOT" 'ssh://git:secret@example.com/repo.git' "$TMP/credential-target" >/dev/null 2>&1; then
  echo "FAIL: SSH credential-bearing remote was accepted" >&2
  exit 1
fi

ln -s "$TMP/workspace" "$TMP/workspace-link"
if bash -c 'source "$1/lib/common.sh"; source "$1/lib/source-policy.sh"; SOURCE_MODE=workspace; WORKSPACE_REPOSITORY_CLONES="$2"$'\''\t'\''"$3"; source_policy_materialize_workspace_repositories' _ "$ROOT" "$ORIGIN" "$TMP/workspace-link/redirected" >/dev/null 2>&1; then
  echo "FAIL: user-controlled symlink ancestor was accepted" >&2
  exit 1
fi

echo "PASS: workspace repositories materialize from persisted host intent"
