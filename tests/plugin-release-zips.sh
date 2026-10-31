#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/wordpress.sh"
source "$ROOT/lib/plugin-upgrade.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SITE_PATH="$tmp/site"
DRY_RUN=false
MULTISITE=false
LOCAL_MODE=true
WP_ROOT_FLAG=''
UPDATED_ITEMS=()
PLUGIN_UPDATE_MUTATED=false
mkdir -p "$tmp/bin"
export RELEASE_FIXTURES="$ROOT/tests/fixtures/plugin-updates" API_CALLS="$tmp/api"
# Stub the real API executable; exercise the actual bounded phase runner.
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$API_CALLS"' 'case "$*" in' '*page=1) /bin/cat "$RELEASE_FIXTURES/releases.json" ;;' '*page=2) if [ "${LEGACY_ONLY:-false}" = true ]; then echo "[]"; else /bin/cat "$RELEASE_FIXTURES/releases-page-2.json"; fi ;;' '*) echo "[]" ;;' 'esac' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
log() { echo "$*"; }
warn() { echo "$*" >&2; }
wp_cmd() {
  printf '%s\n' "$*" >> "$tmp/wp"
  if [ "$1 $2" = 'plugin get' ]; then
    echo "$installed"
  elif [ "$1 $2" = 'option get' ]; then
    [ -f "$tmp/owned" ] && cat "$tmp/owned" || return 1
  elif [ "$1 $2" = 'option update' ]; then
    [ "$DRY_RUN" = true ] || printf '%s\n' "$4" > "$tmp/owned"
  elif [ "$1 $2" = 'plugin install' ]; then
    [ "$DRY_RUN" = true ] || { rm -rf "$SITE_PATH/wp-content/plugins/data-machine"; mkdir -p "$SITE_PATH/wp-content/plugins/data-machine"; }
  fi
}
update() { update_plugin_from_release_zip data-machine Extra-Chill/data-machine data-machine.zip data-machine; }
assert_contains() { grep -Fq -- "$2" "$1" || { echo "Missing: $2" >&2; exit 1; }; }

install_plugin_from_release_zip data-machine Extra-Chill/data-machine data-machine.zip data-machine
assert_contains "$tmp/wp" 'plugin install https://example.test/data-machine.zip --force'
assert_contains "$tmp/wp" 'plugin activate data-machine'
assert_contains "$tmp/api" 'page=3'
assert_contains "$tmp/owned" 'data-machine'
echo 'PASS fresh install, sibling filtering and pagination, ownership recorded'

: > "$tmp/wp"
installed=0.200.1
update
[ "$PLUGIN_UPDATE_MUTATED" = true ]
[ "${UPDATED_ITEMS[0]}" = 'data-machine data-machine-v0.201.0' ]
assert_contains "$tmp/wp" 'plugin install'
echo 'PASS zip upgrade'

: > "$tmp/wp"
PLUGIN_UPDATE_MUTATED=false
installed=0.201.0
update
! grep -q 'plugin install' "$tmp/wp"
[ "$PLUGIN_UPDATE_MUTATED" = false ]
echo 'PASS already current'

plugin_dir="$SITE_PATH/wp-content/plugins/data-machine"
git init -q "$plugin_dir"
git -C "$plugin_dir" -c user.name=Test -c user.email=test@example.test commit -qm initial --allow-empty
update
[ ! -e "$plugin_dir/.git" ]
[ "$PLUGIN_UPDATE_MUTATED" = true ]
echo 'PASS same-version git migration'

git init -q "$plugin_dir"
echo dirty > "$plugin_dir/local.txt"
: > "$tmp/wp"
update
[ -e "$plugin_dir/local.txt" ]
[ ! -s "$tmp/wp" ]
echo 'PASS dirty checkout skipped'
rm -rf "$plugin_dir/.git" "$plugin_dir/local.txt"

installed=0.200.1
DRY_RUN=true
: > "$tmp/wp"
update > "$tmp/dry"
assert_contains "$tmp/dry" '[dry-run] Would install'
assert_contains "$tmp/dry" 'https://example.test/data-machine.zip'
! grep -q 'plugin install' "$tmp/wp"
DRY_RUN=false

installed=0.999.0
: > "$tmp/wp"
update
! grep -q 'plugin install' "$tmp/wp"
echo 'PASS dry run and no downgrade'

# A directory placed by something else (deploy pipeline, wp-admin) is never
# touched: not on upgrade, not on setup.
rm -f "$tmp/owned"
installed=0.100.0
: > "$tmp/wp"
PLUGIN_UPDATE_MUTATED=false
update > "$tmp/foreign"
! grep -q 'plugin install' "$tmp/wp"
[ "$PLUGIN_UPDATE_MUTATED" = false ]
assert_contains "$tmp/foreign" 'managed outside wp-coding-agents'
: > "$tmp/wp"
install_plugin_from_release_zip data-machine Extra-Chill/data-machine data-machine.zip data-machine > "$tmp/foreign"
! grep -q 'plugin install' "$tmp/wp"
assert_contains "$tmp/foreign" 'managed outside wp-coding-agents'
echo 'PASS foreign-managed install left alone'

export LEGACY_ONLY=true
resolved=$(plugin_release_zip_resolve Extra-Chill/data-machine data-machine.zip data-machine)
[[ "$resolved" = *https://example.test/legacy.zip ]]
echo 'PASS legacy-only repository'

# Force the curl fallback without depending on whether gh is host-installed.
command() {
  if [ "$*" = '-v gh' ]; then return 1; fi
  builtin command "$@"
}
curl() {
  printf '%s\n' "$*" >> "$tmp/curl"
  case "${*: -1}" in
    *page=1) /bin/cat "$RELEASE_FIXTURES/releases.json" ;;
    *) echo '[]' ;;
  esac
}
export GH_TOKEN=fixture-token
resolved=$(plugin_release_zip_resolve Extra-Chill/data-machine data-machine.zip data-machine)
[[ "$resolved" = *https://example.test/legacy.zip ]]
assert_contains "$tmp/curl" 'Authorization: Bearer fixture-token'
echo 'PASS authenticated curl fallback'
