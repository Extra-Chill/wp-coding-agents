#!/bin/bash
# tests/source-mode.sh — installed-source mode regression coverage (#314, #324).
#
# Two properties matter here and neither is obvious from reading one file:
#
#   1. Engineering output is UNCHANGED. Every existing install is engineering,
#      so a source-mode refactor that shifts a single glob is a silent permission
#      change on every box in the fleet.
#
#   2. Managed output AGREES WITH ITSELF. The whole reason lib/source-policy.sh
#      exists is that the AGENTS.md prose and the enforced runtime permissions
#      used to be written independently and drifted: h44lacrosse.com shipped an
#      agent told to edit live theme and plugin files while its opencode.json
#      denied exactly those two paths. An owned-mode install that says "editable"
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

rules() { source_policy_edit_rules | awk -F'\t' '{print $1"="$3}' | tr '\n' ' '; }
has_rule() {
  case " $(rules) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
check_rule() {
  if has_rule "$1"; then echo "  ok   $2"; else echo "  FAIL $2 (missing $1)"; FAILED=$((FAILED + 1)); fi
}
refute_rule() {
  if has_rule "$1"; then echo "  FAIL $2 (unexpected $1)"; FAILED=$((FAILED + 1)); else echo "  ok   $2"; fi
}

SOURCE_MODE=workspace
OWNED_SOURCES=""; OWNED_WRITABLE=""; SOURCE_LOG_PATHS=""

# Core is wp-admin AND wp-includes plus the root bootstrap — siblings, not
# nested. Listing only wp-includes left wp-admin and every root PHP file,
# including wp-config.php, editable on every install ever created (#322).
check_rule "wp-admin=deny"                "core admin half is read-only"
check_rule "wp-includes=deny"             "core internals are read-only"
check_rule "wp-config.php=deny"           "wp-config.php is read-only by default"
check_rule "wp-settings.php=deny"         "root bootstrap is read-only"
check_rule "index.php=deny"               "root index.php is read-only"
check_rule "wp-content/mu-plugins=deny"   "agent governance (mu-plugins) is read-only"
check_rule "wp-content/plugins=deny"      "installed plugins are read-only"
check_rule "wp-content/themes=deny"       "installed themes are read-only"

# The agent's own memory lives under uploads; denying it would break the agent.
refute_rule "wp-content/uploads=deny"     "uploads stay writable (agent memory lives there)"
refute_rule "wp-content/uploads=allow"    "uploads are not an owned rule at all"

source_policy_workspace_enabled \
  && echo "  ok   engineering has a workspace" \
  || { echo "  FAIL engineering has a workspace"; FAILED=$((FAILED + 1)); }

# Managed denies the same set and carves out only what was declared.
SOURCE_MODE=owned
OWNED_SOURCES="wp-content/themes/acme
wp-content/plugins/acme-core"
OWNED_WRITABLE=""; SOURCE_LOG_PATHS=""
check_rule "wp-content/plugins=deny"           "owned mode still denies the plugins directory"
check_rule "wp-content/themes/acme=allow"      "owned mode allows a declared owned theme"
check_rule "wp-content/plugins/acme-core=allow" "owned mode allows a declared owned plugin"
check_rule "wp-config.php=deny"                "owned mode still denies wp-config.php by default"

# ORDER is the precedence mechanism for OpenCode findLast.
DENY_POS=$(source_policy_edit_rules | grep -n '^wp-content/plugins	dir	deny$' | cut -d: -f1)
ALLOW_POS=$(source_policy_edit_rules | grep -n '^wp-content/plugins/acme-core	dir	allow$' | cut -d: -f1)
if [ "$DENY_POS" -lt "$ALLOW_POS" ]; then
  echo "  ok   broad deny is emitted before the narrower allow"
else
  echo "  FAIL broad deny is emitted before the narrower allow"
  FAILED=$((FAILED + 1))
fi

source_policy_workspace_enabled \
  && { echo "  FAIL managed has no workspace"; FAILED=$((FAILED + 1)); } \
  || echo "  ok   managed has no workspace"

# Fail closed.
OWNED_SOURCES=""
refute_rule "wp-content/themes/acme=allow" "owned mode with nothing declared grants no edit access"

# Declared writable exceptions re-open a denied path, and are NOT captured.
OWNED_SOURCES=""; OWNED_WRITABLE="wp-config.php"
check_rule "wp-config.php=allow" "a declared writable path re-opens wp-config.php"

# ...but only paths the policy actually denies. Anything else is a typo, and
# accepting it silently would leave the operator believing they granted something.
OWNED_WRITABLE_EXPLICIT=true
OWNED_WRITABLE="wp-config.php nonsense/path.php"
source_policy_resolve_writable_paths 2>/dev/null
assert_eq "$(source_policy_writable_paths | tr '\n' ' ')" "wp-config.php " \
  "unknown writable paths are rejected, not silently granted"
OWNED_WRITABLE_EXPLICIT=false; OWNED_WRITABLE=""

# ===========================================================================
echo "==> the agent can read the logs it needs to recover the site"
# ===========================================================================

# We are strict about editing core, and were accidentally strict about READING
# the one thing needed to recover from a fatal: OpenCode gates paths outside
# the site root behind external_directory, which defaults to "ask" — and an
# autonomous agent has nobody to ask (#322).
SOURCE_LOG_PATHS_EXPLICIT=true
SOURCE_LOG_PATHS="/var/log/nginx relative/nope"
source_policy_resolve_log_paths 2>/dev/null
assert_eq "$(source_policy_log_paths | tr '\n' ' ')" "/var/log/nginx " \
  "log paths must be absolute or they silently do nothing"
# The read-only-ness of a granted log path is enforced where external_directory
# is written — see the opencode section below.

SOURCE_MODE=nonsense
OWNED_SOURCES=""; OWNED_WRITABLE=""
refute_rule "wp-content/plugins=allow" "unknown mode never grants write"

# ===========================================================================
echo "==> runtimes that cannot express scoped permissions refuse owned mode"
# ===========================================================================

for rt in claude-code codex; do
  rc=0
  SOURCE_MODE=owned RUNTIME="$rt" \
    bash -c 'source lib/common.sh; source lib/source-policy.sh; error() { exit 3; }; source_policy_assert_runtime_supports_mode' \
    >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "  ok   $rt refuses owned source mode"
  else
    echo "  FAIL $rt should refuse managed posture (rc=$rc)"
    FAILED=$((FAILED + 1))
  fi
done

rc=0
SOURCE_MODE=owned RUNTIME=opencode \
  bash -c 'source lib/common.sh; source lib/source-policy.sh; error() { exit 3; }; source_policy_assert_runtime_supports_mode' \
  >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok   opencode accepts managed posture"
else
  echo "  FAIL opencode should accept managed posture (rc=$rc)"
  FAILED=$((FAILED + 1))
fi

SOURCE_LOG_PATHS_EXPLICIT=false; SOURCE_LOG_PATHS=""

# ===========================================================================
echo "==> opencode.json permission surface follows the source mode"
# ===========================================================================

_opencode_config_for() {
  local mode="$1" out="$2" sources="${3:-}" logs="${4:-}"
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
    SOURCE_MODE="$mode"
    OWNED_SOURCES="$sources"
    OWNED_WRITABLE=""
    SOURCE_LOG_PATHS="$logs"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/runtimes/opencode.sh"
    runtime_generate_config
    cp "$SITE_PATH/opencode.json" "$out"
  )
}

ENG_JSON="$(mktemp)"; MGD_JSON="$(mktemp)"
trap 'rm -f "$ENG_JSON" "$MGD_JSON"' EXIT
_opencode_config_for workspace "$ENG_JSON"
_opencode_config_for owned "$MGD_JSON" "wp-content/themes/acme
wp-content/plugins/acme-core" "/var/log/site"

ENG_EDIT="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["permission"]["edit"]))' "$ENG_JSON")"
assert_contains "$ENG_EDIT" 'wp-admin/**' "workspace mode denies wp-admin"
assert_contains "$ENG_EDIT" 'wp-config.php' "workspace mode denies wp-config.php"
assert_contains "$ENG_EDIT" 'wp-content/mu-plugins/**' "workspace mode denies mu-plugins"
refute_contains "$ENG_EDIT" 'wp-content/uploads' "workspace mode leaves uploads alone"
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["permission"]["edit"]; print(sorted(set(d.values())))' "$ENG_JSON")" \
  "['deny']" "workspace mode grants no edit allow anywhere in the installed tree"

MGD_EDIT_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permission"]["edit"]))' "$MGD_JSON")"
MGD_KEYS="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["permission"]["edit"]))' "$MGD_JSON")"
assert_contains "$MGD_EDIT_JSON" '"wp-content/plugins/**": "deny"' \
  "managed never opens the whole plugins directory"
assert_contains "$MGD_EDIT_JSON" '"wp-content/themes/acme/**": "allow"' \
  "owned mode allows the declared owned theme"
# sort_keys would destroy the property under test; compare positions instead.
assert_eq "$(python3 -c '
import json,sys
k=list(json.load(open(sys.argv[1]))["permission"]["edit"])
print(k.index("wp-content/themes/**") < k.index("wp-content/themes/acme/**"))' "$MGD_JSON")" \
  "True" "owned mode emits the broad deny before the narrower allow"
assert_contains "$MGD_EDIT_JSON" '"/var/log/site": "deny"' \
  "a readable log path is denied for editing as a literal"
assert_contains "$MGD_EDIT_JSON" '"/var/log/site/**": "deny"' \
  "a readable log path is denied for editing as a subtree"

assert_eq "$(python3 -c 'import json,sys; print("yes" if "external_directory" in json.load(open(sys.argv[1]))["permission"] else "no")' "$ENG_JSON")" \
  "yes" "workspace mode grants the workspace directory"
MGD_EXT="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permission"].get("external_directory",{})))' "$MGD_JSON")"
refute_contains "$MGD_EXT" 'workspace' "owned mode grants no workspace directory (there is none)"
assert_contains "$MGD_EXT" '"/var/log/site/**": "allow"' \
  "managed grants read on the declared log directory"
# A log path may be a single FILE (/var/log/php-fpm.log). Appending /** alone
# matches nothing there — a grant that looks present and does nothing.
assert_contains "$MGD_EXT" '"/var/log/site": "allow"' \
  "the literal log path is granted too, so a file path actually works"

# ===========================================================================
echo "==> claude-code denies every installed root (managed is refused upstream)"
# ===========================================================================

_claude_settings_for() {
  local mode="$1" out="$2" seed="${3:-}"
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
    SOURCE_MODE="$mode"
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
  "workspace mode denies theme edits"
assert_contains "$(cat "$CC_ENG")" '"Edit(SITE_PATH/wp-content/plugins/**)"' \
  "workspace mode denies plugin edits"
assert_contains "$(cat "$CC_ENG")" '"Bash(wp datamachine-code workspace:*)"' \
  "workspace mode allows the DMC workspace bash surface"
rm -f "$CC_ENG"

# ===========================================================================
echo "==> codex filesystem profile keeps every installed root read-only"
# ===========================================================================

_codex_config_for() {
  local mode="$1"
  (
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    export SITE_PATH="$TMP/site" DRY_RUN=false
    mkdir -p "$SITE_PATH/.codex" "$TMP/bin"
    printf '#!/bin/sh\necho "codex-cli 0.142.5"\n' > "$TMP/bin/codex"
    chmod +x "$TMP/bin/codex"
    export PATH="$TMP/bin:$PATH"
    UPDATED_ITEMS=()
    SOURCE_MODE="$mode"
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

SOURCE_MODE=workspace
ENG_PROSE="$(guidance_call wordpress-source render)"
assert_eq "$(guidance_call wordpress-source id)" "wordpress-source" \
  "section id is stable across postures"
assert_contains "$ENG_PROSE" "read-only" "workspace mode prose says read-only"
assert_contains "$ENG_PROSE" "managed workspace" "workspace mode prose routes changes to the workspace"

SOURCE_MODE=owned
OWNED_SOURCES="wp-content/themes/acme
wp-content/plugins/acme-core"
OWNED_WRITABLE="wp-config.php"
MGD_PROSE="$(guidance_call wordpress-source render)"
assert_eq "$(guidance_call wordpress-source id)" "wordpress-source" \
  "managed variant registers the same section id"

# PURPOSE: this section exists so the agent is an expert on its own runtime by
# reading it. Reference comes first; the ownership boundary is a qualifier.
# Restriction is the permission layer's job and is enforced there. #322.
assert_contains "$MGD_PROSE" 'Read it to verify core APIs, hooks, conventions, and runtime behavior' \
  "managed prose leads with reference, not restriction"
assert_contains "$MGD_PROSE" '`wp-admin/`' \
  "managed prose points at wp-admin — core is not just wp-includes"
assert_contains "$MGD_PROSE" '`wp-includes/`' \
  "managed prose points at wp-includes"
assert_contains "$MGD_PROSE" 'ground truth' \
  "managed prose frames installed source as authoritative"


# ENUMERATE, never generalise (#318).
assert_contains "$MGD_PROSE" '- `wp-content/themes/acme/`' \
  "managed prose names each editable path"
assert_contains "$MGD_PROSE" '- `wp-content/plugins/acme-core/`' \
  "managed prose names every editable path, not just the first"
assert_contains "$MGD_PROSE" 'the complete list' \
  "managed prose states the editable list is exhaustive"
refute_contains "$MGD_PROSE" '`wp-content/plugins/` — **editable**' \
  "managed prose never presents a whole directory as editable"

# A writable exception must NOT inherit the "your work is recorded" promise.
assert_contains "$MGD_PROSE" 'nothing captures them' \
  "managed prose says declared writable paths are not captured"
assert_contains "$MGD_PROSE" '- `wp-config.php`' \
  "managed prose names the writable exception"

assert_contains "$MGD_PROSE" 'live the moment you save' \
  "managed prose states that edits reach production immediately"
refute_contains "$MGD_PROSE" "Make code changes in the configured managed workspace" \
  "managed prose never routes work to a workspace that does not exist"

# This text ships to EVERY managed install, so it must not describe one site's
# stack as if it were universal (#320).
for term in WooCommerce Stripe commerce payment money composer.lock package-lock node_modules "Data Machine" homeboy harvest.yml; do
  refute_contains "$MGD_PROSE" "$term" \
    "managed prose does not assume '$term' exists on this install"
done

# Fail closed in prose too.
OWNED_SOURCES=""; OWNED_WRITABLE=""
NONE_PROSE="$(guidance_call wordpress-source render)"
assert_contains "$NONE_PROSE" 'Nothing on this install is declared as editable' \
  "managed prose with nothing declared says so explicitly"
assert_contains "$NONE_PROSE" 'Read it to verify core APIs' \
  "managed prose keeps the reference material even with nothing editable"
OWNED_SOURCES="wp-content/themes/acme"

# Engineering keeps the same capability framing.
SOURCE_MODE=workspace
ENG_PROSE2="$(guidance_call wordpress-source render)"
assert_contains "$ENG_PROSE2" '`wp-admin/`' \
  "workspace mode prose also points at wp-admin"
assert_contains "$ENG_PROSE2" 'ground truth' \
  "workspace mode prose frames installed source as authoritative"
SOURCE_MODE=owned

# The homeboy unit is engineering-only: its routing advice is about cooking
# tracked changes in managed worktrees, which does not exist under managed.
SOURCE_MODE=owned
if guidance_call homeboy applies; then
  echo "  FAIL homeboy guidance must not apply under managed"
  FAILED=$((FAILED + 1))
else
  echo "  ok   homeboy guidance does not apply under managed"
fi

# ===========================================================================
echo "==> opencode.json reconciler honours the source mode"
# ===========================================================================

# #316: the reconciler owned permission.edit only, so a workspace->owned
# upgrade kept a stale workspace grant and declared log paths never landed.
# The upgrade path is the one every real install takes.
EXT_OUT="$(python3 - <<'PYX'
import importlib.util, json, pathlib
spec = importlib.util.spec_from_file_location("repair", pathlib.Path("lib/repair-opencode-json.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
data = {"permission": {"external_directory": {
    "/var/lib/datamachine/workspace/**": "allow",
    "./operator-added": "allow",
}}}
print(json.dumps(mod.expected_external_directory(data, "", ["/var/log/site", "/var/log/one.log"])))
PYX
)"
refute_contains "$EXT_OUT" 'datamachine/workspace' \
  "owned reconcile drops the stale workspace grant"
assert_contains "$EXT_OUT" '"./operator-added": "allow"' \
  "owned reconcile preserves operator-added external grants"
assert_contains "$EXT_OUT" '"/var/log/one.log": "allow"' \
  "a log path naming a file is granted as a literal, not only as a subtree"

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
print(json.dumps(mod.expected_edit_permission(data, "owned", ["wp-content/plugins/acme-core"])))
PYX
)"
assert_contains "$RECON_OUT" '"custom/**": "ask"' \
  "reconciler preserves operator rules"
assert_contains "$RECON_OUT" '"wp-content/plugins/acme-core/**": "allow"' \
  "reconciler writes the owned-source allow"
assert_contains "$RECON_OUT" '"wp-admin/**": "deny"' \
  "reconciler denies wp-admin"
assert_eq "$(python3 -c '
import json,sys
k=list(json.loads(sys.argv[1]))
print(k.index("wp-content/plugins/**") < k.index("wp-content/plugins/acme-core/**"))' "$RECON_OUT")" \
  "True" "reconciler emits denies before owned allows"
rm -f "$RECON_IN"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi

echo
echo "OK: all source-mode assertions passed"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ===========================================================================
echo "==> the #324 rename carries existing installs across"
# ===========================================================================

# Renaming is only safe if every install that recorded the old vocabulary keeps
# working without the operator touching anything. Two live installs recorded
# `wp_coding_agents_posture` before this change; an upgrade that read an empty
# new key and fell through to the default would silently revert a managed box
# to workspace mode and hand its agent a workspace it does not have.

assert_eq "$(source_policy_canonical_mode engineering)" "workspace" "engineering -> workspace"
assert_eq "$(source_policy_canonical_mode managed)" "owned" "managed -> owned"
assert_eq "$(source_policy_canonical_mode workspace)" "workspace" "workspace passes through"
assert_eq "$(source_policy_canonical_mode owned)" "owned" "owned passes through"
assert_eq "$(source_policy_canonical_mode nonsense)" "nonsense" "unknown passes through to fail validation"
assert_eq "$(source_policy_canonical_mode '')" "" "empty passes through"

# The deprecated flag spelling must resolve to the new value, not error.
for legacy_pair in "engineering workspace" "managed owned"; do
  set -- $legacy_pair
  got=$(
    SOURCE_MODE="$1" SOURCE_MODE_EXPLICIT=true DRY_RUN=true
    log() { :; }; error() { echo "ERROR: $*"; exit 1; }
    source_policy_resolve_mode >/dev/null 2>&1
    printf '%s' "$SOURCE_MODE"
  )
  assert_eq "$got" "$2" "--posture $1 resolves to $2"
done

# A recorded legacy value must resolve the same way. This is the upgrade path
# every existing install takes.
for legacy_pair in "engineering workspace" "managed owned"; do
  set -- $legacy_pair
  got=$(
    SOURCE_MODE_EXPLICIT=false DRY_RUN=false SITE_PATH="$TMPD/site"
    mkdir -p "$SITE_PATH"; : > "$SITE_PATH/wp-config.php"
    log() { :; }; error() { echo "ERROR: $*"; exit 1; }
    # Legacy key populated, new key empty — the pre-rename install.
    LEGACY="$1"
    wp_cmd() {
      case "$*" in
        *"option get wp_coding_agents_source_mode"*) return 0 ;;
        *"option get wp_coding_agents_posture"*) echo "$LEGACY" ;;
        *) return 0 ;;
      esac
    }
    source_policy_resolve_mode >/dev/null 2>&1
    printf '%s' "$SOURCE_MODE"
  )
  assert_eq "$got" "$2" "recorded '$1' resolves to $2 on upgrade"
done

# ...and the migration must actually WRITE the new key. Comparing through the
# legacy-aware reader would see a pre-rename install as already correct — the
# canonical value of `engineering` IS `workspace` — and leave it on the old key
# forever, so the rename would never complete.
#
# The call site redirects wp_cmd's output to /dev/null, so the stub records what
# it was asked to do in a file rather than on a stream nobody can see.
PROBE="$TMPD/option-writes"
: > "$PROBE"
(
  SOURCE_MODE="workspace" DRY_RUN=false SITE_PATH="$TMPD/site2"
  mkdir -p "$SITE_PATH"; : > "$SITE_PATH/wp-config.php"
  log() { :; }; warn() { :; }
  wp_cmd() {
    case "$*" in
      *"option get wp_coding_agents_source_mode"*) return 0 ;;
      *"option get wp_coding_agents_posture"*) echo "engineering" ;;
      *"option update wp_coding_agents_source_mode"*)
        echo "$*" >> "$PROBE" ;;
      *) return 0 ;;
    esac
  }
  source_policy_record_mode >/dev/null 2>&1
)
assert_contains "$(cat "$PROBE")" "option update wp_coding_agents_source_mode workspace" \
  "record_mode migrates a legacy install onto the new key"

# And it must be idempotent: once the new key holds the value, no second write.
: > "$PROBE"
(
  SOURCE_MODE="workspace" DRY_RUN=false SITE_PATH="$TMPD/site3"
  mkdir -p "$SITE_PATH"; : > "$SITE_PATH/wp-config.php"
  log() { :; }; warn() { :; }
  wp_cmd() {
    case "$*" in
      *"option get wp_coding_agents_source_mode"*) echo "workspace" ;;
      *"option update"*) echo "$*" >> "$PROBE" ;;
      *) return 0 ;;
    esac
  }
  source_policy_record_mode >/dev/null 2>&1
)
assert_eq "$(cat "$PROBE")" "" "record_mode does not rewrite an already-migrated install"
