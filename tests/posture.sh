#!/bin/bash
# tests/posture.sh — installed-source posture regression coverage (#314).
#
# Two properties matter here and neither is obvious from reading one file:
#
#   1. Engineering output is UNCHANGED. Every existing install is engineering,
#      so a posture refactor that shifts a single glob is a silent permission
#      change on every box in the fleet.
#
#   2. Managed output AGREES WITH ITSELF. The whole reason lib/source-policy.sh
#      exists is that the AGENTS.md prose and the enforced runtime permissions
#      used to be written independently and drifted: h44lacrosse.com shipped an
#      agent told to edit live theme and plugin files while its opencode.json
#      denied exactly those two paths. A managed install that says "editable"
#      in prose and "deny" in permissions is the bug, not a cosmetic mismatch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

FAILED=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    echo "         got:  $got"
    echo "         want: $want"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) echo "  ok   $name" ;;
    *)
      echo "  FAIL $name (missing: $needle)"
      FAILED=$((FAILED + 1))
      ;;
  esac
}

refute_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  FAIL $name (unexpectedly present: $needle)"
      FAILED=$((FAILED + 1))
      ;;
    *) echo "  ok   $name" ;;
  esac
}

log() { :; }
warn() { printf '%s\n' "$*" >&2; }
error() { printf '%s\n' "$*" >&2; return 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"

# ===========================================================================
echo "==> source policy resolves the documented root matrix"
# ===========================================================================

POSTURE=engineering
MANAGED_SOURCES=""
assert_eq "$(source_policy_edit_rules | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=deny wp-content/themes=deny wp-includes=deny " \
  "engineering keeps every installed root read-only"
source_policy_workspace_enabled \
  && echo "  ok   engineering has a workspace" \
  || { echo "  FAIL engineering has a workspace"; FAILED=$((FAILED + 1)); }

# Managed does NOT open wp-content. It denies the same roots and then carves
# out only the declared owned paths. The regression this pins: an earlier
# version allowed `wp-content/plugins/**` wholesale, which on a live install
# meant WooCommerce, a payment gateway, and the agent's own runtime.
POSTURE=managed
MANAGED_SOURCES="wp-content/themes/acme
wp-content/plugins/acme-core"
assert_eq "$(source_policy_edit_rules | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=deny wp-content/themes=deny wp-includes=deny wp-content/themes/acme=allow wp-content/plugins/acme-core=allow " \
  "managed denies the roots and allows only declared owned paths"

# Order is the precedence mechanism for OpenCode findLast; a narrower allow
# emitted before the broad deny would be silently inverted.
DENY_POS=$(source_policy_edit_rules | grep -n '^wp-content/plugins	deny$' | cut -d: -f1)
ALLOW_POS=$(source_policy_edit_rules | grep -n '^wp-content/plugins/acme-core	allow$' | cut -d: -f1)
[ "$DENY_POS" -lt "$ALLOW_POS" ]
check_rc=$?
if [ "$check_rc" -eq 0 ]; then
  echo "  ok   broad deny is emitted before the narrower allow"
else
  echo "  FAIL broad deny is emitted before the narrower allow"
  FAILED=$((FAILED + 1))
fi

source_policy_workspace_enabled \
  && { echo "  FAIL managed has no workspace"; FAILED=$((FAILED + 1)); } \
  || echo "  ok   managed has no workspace"

# Fail closed: a managed install that declares nothing gets NO editable source
# rather than a wide-open wp-content.
POSTURE=managed
MANAGED_SOURCES=""
assert_eq "$(source_policy_edit_rules | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=deny wp-content/themes=deny wp-includes=deny " \
  "managed with nothing declared grants no edit access at all"

# Paths outside wp-content, and files inside a component, are rejected rather
# than silently trusted.
MANAGED_SOURCES_EXPLICIT=true
MANAGED_SOURCES="wp-includes/foo wp-content/plugins/acme/file.php wp-content/plugins/acme"
source_policy_resolve_owned_sources 2>/dev/null
assert_eq "$(source_policy_owned_sources | tr '\n' ' ')" "wp-content/plugins/acme " \
  "only well-formed plugin/theme directories survive normalization"

POSTURE=nonsense
MANAGED_SOURCES=""
assert_eq "$(source_policy_edit_rules | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=deny wp-content/themes=deny wp-includes=deny " \
  "unknown posture degrades to read-only, never to write"

# ===========================================================================
echo "==> runtimes that cannot express scoped permissions refuse managed"
# ===========================================================================

for rt in claude-code codex; do
  rc=0
  POSTURE=managed RUNTIME="$rt" \
    bash -c 'source lib/common.sh; source lib/source-policy.sh; error() { exit 3; }; source_policy_assert_runtime_supports_posture' \
    >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "  ok   $rt refuses managed posture"
  else
    echo "  FAIL $rt should refuse managed posture (rc=$rc)"
    FAILED=$((FAILED + 1))
  fi
done

rc=0
POSTURE=managed RUNTIME=opencode \
  bash -c 'source lib/common.sh; source lib/source-policy.sh; error() { exit 3; }; source_policy_assert_runtime_supports_posture' \
  >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok   opencode accepts managed posture"
else
  echo "  FAIL opencode should accept managed posture (rc=$rc)"
  FAILED=$((FAILED + 1))
fi

# ===========================================================================
echo "==> opencode.json permission surface follows posture"
# ===========================================================================

_opencode_config_for() {
  local posture="$1" out="$2" sources="${3:-}"
  (
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    SITE_PATH="$TMP/site"
    KIMAKI_DATA_DIR="$TMP/kimaki-data"
    mkdir -p "$SITE_PATH" "$KIMAKI_DATA_DIR"
    export SCRIPT_DIR SITE_PATH KIMAKI_DATA_DIR
    export CHAT_BRIDGE="kimaki" LOCAL_MODE=true DRY_RUN=false
    export OPENCODE_MODEL="" OPENCODE_SMALL_MODEL=""
    export DM_WORKSPACE_DIR="$TMP/workspace"
    export DM_AGENT_FILES=""
    export WITH_CLAUDE_CODE_AUTH=false RUNTIME="opencode"
    UPDATED_ITEMS=()
    POSTURE="$posture"
    MANAGED_SOURCES="$sources"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/runtimes/opencode.sh"
    runtime_generate_config
    cp "$SITE_PATH/opencode.json" "$out"
  )
}

ENG_JSON="$(mktemp)"; MGD_JSON="$(mktemp)"
trap 'rm -f "$ENG_JSON" "$MGD_JSON"' EXIT
_opencode_config_for engineering "$ENG_JSON"
_opencode_config_for managed "$MGD_JSON" "wp-content/themes/acme
wp-content/plugins/acme-core"

assert_eq "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permission"]["edit"],sort_keys=True))' "$ENG_JSON")" \
  '{"wp-content/plugins/**": "deny", "wp-content/themes/**": "deny", "wp-includes/**": "deny"}' \
  "engineering opencode edit map is byte-identical to the pre-refactor rules"

# sort_keys would destroy the very thing under test, so compare raw order.
assert_eq "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permission"]["edit"]))' "$MGD_JSON")" \
  '{"wp-content/plugins/**": "deny", "wp-content/themes/**": "deny", "wp-includes/**": "deny", "wp-content/themes/acme/**": "allow", "wp-content/plugins/acme-core/**": "allow"}' \
  "managed opencode edit map denies the roots then allows owned paths, in that order"

MGD_EDIT="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["permission"]["edit"]))' "$MGD_JSON")"
refute_contains "$MGD_EDIT" 'wp-content/plugins/**": "allow' \
  "managed never opens the whole plugins directory"

assert_eq "$(python3 -c 'import json,sys; print("yes" if "external_directory" in json.load(open(sys.argv[1]))["permission"] else "no")' "$ENG_JSON")" \
  "yes" "engineering grants the workspace directory"
assert_eq "$(python3 -c 'import json,sys; print("yes" if "external_directory" in json.load(open(sys.argv[1]))["permission"] else "no")' "$MGD_JSON")" \
  "no" "managed grants no workspace directory (there is none)"

# ===========================================================================
echo "==> claude-code denies every installed root (managed is refused upstream)"
# ===========================================================================

_claude_settings_for() {
  local posture="$1" out="$2" seed="${3:-}"
  (
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    export SITE_PATH="$TMP/site"
    export DM_WORKSPACE_DIR="$TMP/workspace"
    export AGENT_SLUG="builder" DRY_RUN=false IS_STUDIO=false
    mkdir -p "$SITE_PATH/.claude" "$DM_WORKSPACE_DIR"
    if [ -n "$seed" ]; then
      sed "s|SITE_PATH|$SITE_PATH|g" "$seed" > "$SITE_PATH/.claude/settings.json"
    fi
    UPDATED_ITEMS=()
    POSTURE="$posture"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/runtimes/claude-code.sh"
    runtime_install_hooks >/dev/null 2>&1
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' \
      "$SITE_PATH/.claude/settings.json" | sed "s|$SITE_PATH|SITE_PATH|g" > "$out"
  )
}

CC_ENG="$(mktemp)"
_claude_settings_for engineering "$CC_ENG"
assert_contains "$(cat "$CC_ENG")" '"Edit(SITE_PATH/wp-content/themes/**)"' \
  "engineering denies theme edits"
assert_contains "$(cat "$CC_ENG")" '"Edit(SITE_PATH/wp-content/plugins/**)"' \
  "engineering denies plugin edits"
assert_contains "$(cat "$CC_ENG")" '"Bash(wp datamachine-code workspace:*)"' \
  "engineering allows the DMC workspace bash surface"
rm -f "$CC_ENG"

# ===========================================================================
echo "==> codex filesystem profile keeps every installed root read-only"
# ===========================================================================

_codex_config_for() {
  local posture="$1"
  (
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    export SITE_PATH="$TMP/site" DRY_RUN=false
    mkdir -p "$SITE_PATH/.codex" "$TMP/bin"
    printf '#!/bin/sh\necho "codex-cli 0.142.5"\n' > "$TMP/bin/codex"
    chmod +x "$TMP/bin/codex"
    export PATH="$TMP/bin:$PATH"
    UPDATED_ITEMS=()
    POSTURE="$posture"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/runtimes/codex.sh"
    runtime_generate_config >/dev/null 2>&1
    cat "$SITE_PATH/.codex/config.toml"
  )
}

CX_ENG="$(_codex_config_for engineering)"
assert_contains "$CX_ENG" '"wp-content/themes" = "read"' "codex profile keeps themes read-only"
assert_contains "$CX_ENG" '"wp-content/plugins" = "read"' "codex profile keeps plugins read-only"
assert_contains "$CX_ENG" '"wp-includes" = "read"' "codex profile keeps core read-only"

# ===========================================================================
echo "==> AGENTS.md guidance agrees with the enforced permissions"
# ===========================================================================

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/agents-md-guidance.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/guidance/_dispatch.sh"

POSTURE=engineering
ENG_PROSE="$(guidance_call wordpress-source render)"
assert_eq "$(guidance_call wordpress-source id)" "wordpress-source" \
  "section id is stable across postures"
assert_contains "$ENG_PROSE" "read-only" "engineering prose says read-only"
assert_contains "$ENG_PROSE" "managed workspace" "engineering prose routes changes to the workspace"

POSTURE=managed
MANAGED_SOURCES="wp-content/themes/acme
wp-content/plugins/acme-core"
MGD_PROSE="$(guidance_call wordpress-source render)"
assert_eq "$(guidance_call wordpress-source id)" "wordpress-source" \
  "managed variant registers the same section id"

# The prose must ENUMERATE, never generalise to a directory. Saying "this
# site's theme and plugins" while the policy lists two paths is how an agent
# concludes WooCommerce is fair game.
assert_contains "$MGD_PROSE" '- `wp-content/themes/acme/`' \
  "managed prose names each editable path"
assert_contains "$MGD_PROSE" '- `wp-content/plugins/acme-core/`' \
  "managed prose names every editable path, not just the first"
assert_contains "$MGD_PROSE" 'this is the complete list' \
  "managed prose states the editable list is exhaustive"
refute_contains "$MGD_PROSE" '`wp-content/plugins/` -- **editable**' \
  "managed prose never presents a whole directory as editable"
assert_contains "$MGD_PROSE" 'The rest of `wp-content/plugins/`' \
  "managed prose marks the remaining plugins read-only"
assert_contains "$MGD_PROSE" '`wp-includes/` ' \
  "managed prose keeps core read-only"
assert_contains "$MGD_PROSE" 'live the moment you save' \
  "managed prose states that edits reach production immediately"
assert_contains "$MGD_PROSE" 'not every file is authored source' \
  "managed prose warns that installed and generated files are not captured"
assert_contains "$MGD_PROSE" 'no pull request step' \
  "managed prose rules out the review workflow rather than leaving it implied"
refute_contains "$MGD_PROSE" "Make code changes in the configured managed workspace" \
  "managed prose never routes work to a workspace that does not exist"

# This text ships to EVERY managed install, so it must not describe one site's
# stack as if it were universal. #320: it named commerce and payment code, "the
# site's ability to take money", called the remaining plugins "the runtime that
# gives you memory and tools", and listed one operator's harvest excludes
# verbatim — a config wp-coding-agents does not own and cannot read. Assert the
# CATEGORY and the REASON; never the specifics.
for term in WooCommerce Stripe commerce payment money composer.lock package-lock node_modules "Data Machine" homeboy harvest.yml wp-admin; do
  refute_contains "$MGD_PROSE" "$term" \
    "managed prose does not assume '$term' exists on this install"
done

# Fail closed in prose too: nothing declared must not read as "edit anything".
MANAGED_SOURCES=""
NONE_PROSE="$(guidance_call wordpress-source render)"
assert_contains "$NONE_PROSE" 'declares no editable source' \
  "managed prose with nothing declared says so explicitly"
refute_contains "$NONE_PROSE" 'You edit this site directly' \
  "managed prose with nothing declared does not invite edits"
MANAGED_SOURCES="wp-content/themes/acme"

# The homeboy unit is engineering-only: its routing advice is about cooking
# tracked changes in managed worktrees, which does not exist under managed.
POSTURE=managed
if guidance_call homeboy applies; then
  echo "  FAIL homeboy guidance must not apply under managed"
  FAILED=$((FAILED + 1))
else
  echo "  ok   homeboy guidance does not apply under managed"
fi

# ===========================================================================
echo "==> opencode.json reconciler honours posture"
# ===========================================================================

RECON_IN="$(mktemp)"
cat > "$RECON_IN" <<'JSON'
{"permission":{"edit":{"wp-content/plugins/**":"deny","wp-content/themes/**":"deny","wp-includes/**":"deny","custom/**":"ask"}}}
JSON
RECON_OUT="$(python3 - "$RECON_IN" <<'PYX'
import importlib.util, json, sys, pathlib
spec = importlib.util.spec_from_file_location("repair", pathlib.Path("lib/repair-opencode-json.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
data = json.load(open(sys.argv[1]))
# json.dumps preserves insertion order, which is the property under test.
print(json.dumps(mod.expected_edit_permission(data, "managed", ["wp-content/plugins/acme-core"])))
PYX
)"
assert_eq "$RECON_OUT" \
  '{"custom/**": "ask", "wp-content/plugins/**": "deny", "wp-content/themes/**": "deny", "wp-includes/**": "deny", "wp-content/plugins/acme-core/**": "allow"}' \
  "reconciler emits denies before owned allows and preserves operator rules"
rm -f "$RECON_IN"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo
echo "OK: all posture assertions passed"
