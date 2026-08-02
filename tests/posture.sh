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
assert_eq "$(source_policy_root_actions | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=deny wp-content/themes=deny wp-includes=deny " \
  "engineering keeps every installed root read-only"
source_policy_workspace_enabled \
  && echo "  ok   engineering has a workspace" \
  || { echo "  FAIL engineering has a workspace"; FAILED=$((FAILED + 1)); }

POSTURE=managed
assert_eq "$(source_policy_root_actions | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=allow wp-content/themes=allow wp-includes=deny " \
  "managed opens themes and plugins but never core"
source_policy_workspace_enabled \
  && { echo "  FAIL managed has no workspace"; FAILED=$((FAILED + 1)); } \
  || echo "  ok   managed has no workspace"

# An unrecognised posture must fall back to the safe (read-only) matrix rather
# than silently granting write access to a live site.
POSTURE=nonsense
assert_eq "$(source_policy_root_actions | tr '\t' '=' | tr '\n' ' ')" \
  "wp-content/plugins=deny wp-content/themes=deny wp-includes=deny " \
  "unknown posture degrades to read-only, never to write"

# ===========================================================================
echo "==> opencode.json permission surface follows posture"
# ===========================================================================

_opencode_config_for() {
  local posture="$1" out="$2"
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
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/runtimes/opencode.sh"
    runtime_generate_config
    cp "$SITE_PATH/opencode.json" "$out"
  )
}

ENG_JSON="$(mktemp)"; MGD_JSON="$(mktemp)"
trap 'rm -f "$ENG_JSON" "$MGD_JSON"' EXIT
_opencode_config_for engineering "$ENG_JSON"
_opencode_config_for managed "$MGD_JSON"

assert_eq "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permission"]["edit"],sort_keys=True))' "$ENG_JSON")" \
  '{"wp-content/plugins/**": "deny", "wp-content/themes/**": "deny", "wp-includes/**": "deny"}' \
  "engineering opencode edit map is byte-identical to the pre-refactor rules"

assert_eq "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permission"]["edit"],sort_keys=True))' "$MGD_JSON")" \
  '{"wp-content/plugins/**": "allow", "wp-content/themes/**": "allow", "wp-includes/**": "deny"}' \
  "managed opencode edit map opens the live working tree"

assert_eq "$(python3 -c 'import json,sys; print("yes" if "external_directory" in json.load(open(sys.argv[1]))["permission"] else "no")' "$ENG_JSON")" \
  "yes" "engineering grants the workspace directory"
assert_eq "$(python3 -c 'import json,sys; print("yes" if "external_directory" in json.load(open(sys.argv[1]))["permission"] else "no")' "$MGD_JSON")" \
  "no" "managed grants no workspace directory (there is none)"

# ===========================================================================
echo "==> claude-code settings.json follows posture, and switching clears denies"
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

CC_ENG="$(mktemp)"; CC_MGD="$(mktemp)"; CC_SEED="$(mktemp)"
_claude_settings_for engineering "$CC_ENG"
assert_contains "$(cat "$CC_ENG")" '"Edit(SITE_PATH/wp-content/themes/**)"' \
  "engineering denies theme edits"
assert_contains "$(cat "$CC_ENG")" '"Bash(wp datamachine-code workspace:*)"' \
  "engineering allows the DMC workspace bash surface"

# Seed a settings.json that already carries the engineering denies, then sync
# under managed. A posture switch has to REMOVE the stale denies; leaving them
# is precisely the failure mode that blocked h44-bot from its own theme.
cat > "$CC_SEED" <<'JSON'
{"permissions":{"deny":["Read(./private/**)","Edit(SITE_PATH/wp-content/plugins/**)","Edit(SITE_PATH/wp-content/themes/**)","Edit(SITE_PATH/wp-includes/**)"]}}
JSON
_claude_settings_for managed "$CC_MGD" "$CC_SEED"
refute_contains "$(cat "$CC_MGD")" '"Edit(SITE_PATH/wp-content/themes/**)"' \
  "managed sync clears the stale theme deny"
refute_contains "$(cat "$CC_MGD")" '"Edit(SITE_PATH/wp-content/plugins/**)"' \
  "managed sync clears the stale plugin deny"
assert_contains "$(cat "$CC_MGD")" '"Edit(SITE_PATH/wp-includes/**)"' \
  "managed still denies WordPress core"
assert_contains "$(cat "$CC_MGD")" '"Read(./private/**)"' \
  "managed sync preserves unrelated operator denies"
refute_contains "$(cat "$CC_MGD")" 'datamachine-code workspace' \
  "managed grants no workspace bash surface"
rm -f "$CC_ENG" "$CC_MGD" "$CC_SEED"

# ===========================================================================
echo "==> codex filesystem profile follows posture"
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
CX_MGD="$(_codex_config_for managed)"
assert_contains "$CX_ENG" '"wp-content/themes" = "read"' "engineering codex profile keeps themes read-only"
assert_contains "$CX_ENG" '"wp-includes" = "read"' "engineering codex profile keeps core read-only"
refute_contains "$CX_MGD" '"wp-content/themes" = "read"' "managed codex profile drops the theme read-only rule"
refute_contains "$CX_MGD" '"wp-content/plugins" = "read"' "managed codex profile drops the plugin read-only rule"
assert_contains "$CX_MGD" '"wp-includes" = "read"' "managed codex profile still protects core"

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
MGD_PROSE="$(guidance_call wordpress-source render)"
assert_eq "$(guidance_call wordpress-source id)" "wordpress-source" \
  "managed variant registers the same section id"
assert_contains "$MGD_PROSE" '`wp-content/themes/` — **editable**' \
  "managed prose declares themes editable, matching permission.edit"
assert_contains "$MGD_PROSE" '`wp-includes/` — WordPress core, **read-only**' \
  "managed prose keeps core read-only, matching permission.edit"
assert_contains "$MGD_PROSE" "live the moment you save" \
  "managed prose states that edits reach production immediately"
assert_contains "$MGD_PROSE" "never recorded" \
  "managed prose warns about paths a capture silently skips"
assert_contains "$MGD_PROSE" "no pull request step" \
  "managed prose rules out the review workflow rather than leaving it implied"
refute_contains "$MGD_PROSE" "Make code changes in the configured managed workspace" \
  "managed prose never routes work to a workspace that does not exist"

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
RECON_OUT="$(python3 - "$RECON_IN" <<'PY'
import importlib.util, json, sys, pathlib
spec = importlib.util.spec_from_file_location("repair", pathlib.Path("lib/repair-opencode-json.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
data = json.load(open(sys.argv[1]))
print(json.dumps(mod.expected_edit_permission(data, "managed"), sort_keys=True))
PY
)"
assert_eq "$RECON_OUT" \
  '{"custom/**": "ask", "wp-content/plugins/**": "allow", "wp-content/themes/**": "allow", "wp-includes/**": "deny"}' \
  "reconciler rewrites managed rules and preserves operator rules"
rm -f "$RECON_IN"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo
echo "OK: all posture assertions passed"
