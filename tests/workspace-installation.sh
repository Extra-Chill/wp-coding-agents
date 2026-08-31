#!/bin/bash
# A DMC-free workspace fixture: generated runtime state must be sufficient for
# native repository work and optional Homeboy ownership.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SITE="$TMP/site"
REPOSITORY="$TMP/repository"
BIN="$TMP/bin"
mkdir -p "$SITE/wp-content/plugins" "$REPOSITORY" "$BIN"
: > "$SITE/wp-config.php"

fail() { echo "FAIL: $*" >&2; exit 1; }

git -C "$REPOSITORY" init -q
git -C "$REPOSITORY" config user.email fixture@example.test
git -C "$REPOSITORY" config user.name Fixture
printf 'initial\n' > "$REPOSITORY/plugin.php"
git -C "$REPOSITORY" add plugin.php
git -C "$REPOSITORY" commit -qm initial

# The real focused plugin remains loadable without DMC and only registers its
# consumer-bound WordPress capability hooks.
php -r '
define("ABSPATH", __DIR__);
$hooks = array();
function add_filter($hook, $callback) { global $hooks; $hooks[$hook] = $callback; }
require $argv[1];
if (!isset($hooks["intelligence_host_has_shell"], $hooks["intelligence_host_has_writable_content_directory"])) exit(1);
foreach (array_keys($hooks) as $hook) if (str_contains($hook, "datamachine")) exit(1);
' "$ROOT/carried-plugins/wp-coding-agents-integration/wp-coding-agents-integration.php" || fail "focused WordPress integration requires DMC"

source "$ROOT/lib/common.sh"
source "$ROOT/lib/source-policy.sh"
source "$ROOT/lib/desired-state-reconciler.sh"

SITE_PATH="$SITE"
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
IS_STUDIO=true
SOURCE_MODE=workspace
RUNTIME=opencode
CHAT_BRIDGE=""
HOMEBOY_MODE=enabled
INSTALL_CHAT=false
DRY_RUN=false
WORKSPACE_REPOSITORIES="$REPOSITORY"
DETECTED_RUNTIMES=()
installation_profile_normalize "$INSTALLATION_OPERATION_SETUP"
installation_profile_write

UPDATED_ITEMS=()
KIMAKI_DATA_DIR="$TMP/kimaki"
DM_WORKSPACE_DIR="$TMP/not-authoritative"
DM_AGENT_FILES=""
WITH_CLAUDE_CODE_AUTH=false
OPENCODE_MODEL=""
OPENCODE_SMALL_MODEL=""
SCRIPT_DIR="$ROOT"
source "$ROOT/runtimes/opencode.sh"
runtime_generate_config

python3 - "$SITE/opencode.json" "$REPOSITORY" <<'PY' || fail "generated OpenCode configuration omitted repository access"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["permission"]["external_directory"][sys.argv[2] + "/**"] == "allow"
assert data["permission"]["edit"]["wp-content/plugins/**"] == "deny"
PY

source "$ROOT/guidance/wordpress-source.workspace.sh"
GUIDANCE="$(guidance_render)"
case "$GUIDANCE" in *"read-only reference"*"$REPOSITORY"*) ;; *) fail "workspace guidance did not route to the declared repository" ;; esac

printf 'changed\n' >> "$REPOSITORY/plugin.php"
git -C "$REPOSITORY" status --short | grep -q ' M plugin.php' || fail "native Git status did not observe the edit"
git -C "$REPOSITORY" diff -- plugin.php | grep -q '+changed' || fail "native Git diff did not contain the edit"
git -C "$REPOSITORY" add plugin.php
git -C "$REPOSITORY" commit -qm 'test: fixture native edit'
test "$(git -C "$REPOSITORY" status --short)" = "" || fail "native Git commit left the repository dirty"

cat > "$BIN/wp" <<'SH'
#!/bin/bash
case "$3" in wp_coding_agents_source_mode) echo workspace ;; esac
SH
chmod +x "$BIN/wp"
PATH="$BIN:$PATH" "$ROOT/verify.sh" --site-path "$SITE" --quiet || fail "verify rejected the healthy workspace fixture"

python3 - "$SITE/opencode.json" "$REPOSITORY" <<'PY'
import json, sys
path, repository = sys.argv[1:]
data = json.load(open(path))
del data["permission"]["external_directory"][repository + "/**"]
json.dump(data, open(path, "w"))
PY
if PATH="$BIN:$PATH" "$ROOT/verify.sh" --site-path "$SITE" --quiet; then
  fail "verify missed a repository permission disagreement"
fi

cat > "$BIN/homeboy" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOMEBOY_LOG"
case "$*" in
  "config show /worktree_providers/dmc") test -f "$HOMEBOY_PROVIDER" ;;
  "config remove /worktree_providers/dmc") rm -f "$HOMEBOY_PROVIDER" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN/homeboy"
PATH="$BIN:$PATH"
source "$ROOT/lib/homeboy.sh"
HOMEBOY_LOG="$TMP/homeboy.log"
HOMEBOY_PROVIDER="$TMP/provider"
touch "$HOMEBOY_PROVIDER"
export HOMEBOY_LOG HOMEBOY_PROVIDER PATH
UPDATED_ITEMS=()
configure_homeboy_worktree_ownership
test ! -e "$HOMEBOY_PROVIDER" || fail "Homeboy retained a DMC provider"
test ! -e "$SITE/wp-content/mu-plugins/wp-coding-agents-homeboy-worktrees.php" || fail "DMC-free Homeboy ownership installed an ability callback"

test ! -d "$SITE/wp-content/plugins/data-machine-code" || fail "fixture installed data-machine-code"
echo "PASS: DMC-free workspace installation fixture"
