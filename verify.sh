#!/bin/bash
# verify.sh — assert the cross-layer invariants on an installed agent.
#
# WHY THIS EXISTS
#
# Every defect that reached a live site during the managed-hosting rollout was a
# disagreement BETWEEN layers, not a fault within one:
#
#   unit User= vs unit HOME            the agent ran with a home it cannot read
#   recorded option vs manifest file   capture read a set the site had moved on from
#   manifest vs harvest components     a hardcoded list drifted from the declaration
#   owned set vs permission.edit       declared editable, actually denied
#   function vs the lib its caller sources
#                                      a guard silently skipped, leaving database
#                                      credentials group-writable
#
# Each component was internally correct and individually tested. Nothing owned
# the seam, so nothing failed until someone looked — and the looking is what
# does not scale. An operator with two sites inspects a rendered systemd unit
# before starting services. An operator with two thousand does not.
#
# So the seams get an owner. This asserts them, exits non-zero on disagreement,
# and is cheap enough to run on a schedule.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It never repairs. A check that fixes what it finds cannot be trusted to report
# honestly, and the failure it hides is exactly the one worth seeing: silent
# convergence is how "it works on my box" survives. `./upgrade.sh` is the
# repair; this is the measurement.
#
# Usage:
#   ./verify.sh [--site-path PATH] [--quiet] [--json]
#
# Exit: 0 all invariants hold, 1 at least one disagreement, 2 cannot check.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

QUIET=false
JSON=false
SITE_PATH="${SITE_PATH:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --site-path) SITE_PATH="$2"; shift 2 ;;
    --quiet)     QUIET=true; shift ;;
    --json)      JSON=true; QUIET=true; shift ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) shift ;;
  esac
done

PASSED=0
FAILED=0
SKIPPED=0
FINDINGS=""

_say() { [ "$QUIET" = true ] || printf '%s\n' "$1"; }

pass() {
  PASSED=$((PASSED + 1))
  _say "  ok    $1"
}

# A disagreement. The message must name BOTH sides — "permissions are wrong" is
# not actionable; "declared X, permission.edit allows Y" is.
fail() {
  FAILED=$((FAILED + 1))
  FINDINGS="${FINDINGS}${1}"$'\n'
  _say "  FAIL  $1"
}

# Something this cannot see from here. Distinct from a pass on purpose: an
# invariant that could not be checked has not been shown to hold, and reporting
# it as fine is how a check becomes decoration.
skip() {
  SKIPPED=$((SKIPPED + 1))
  _say "  skip  $1"
}

section() { _say ""; _say "$1"; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

if [ -z "$SITE_PATH" ]; then
  for candidate in /var/www/*/; do
    [ -f "${candidate}wp-config.php" ] || continue
    SITE_PATH="${candidate%/}"
    break
  done
fi

if [ -z "$SITE_PATH" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
  echo "verify: no WordPress install found (pass --site-path)" >&2
  exit 2
fi

wp_cli_transport_ensure
command -v "${WP_CLI_TRANSPORT[0]}" >/dev/null 2>&1 || { echo "verify: $(wp_cli_transport_display) not on PATH" >&2; exit 2; }
WP_ROOT_FLAG=""
[ "$(id -u)" -eq 0 ] && WP_ROOT_FLAG="--allow-root"

wp_opt() {
  wp_cli option get "$1" $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || true
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

SOURCE_MODE="$(wp_opt wp_coding_agents_source_mode | tr -d '[:space:]')"
[ -n "$SOURCE_MODE" ] || SOURCE_MODE="$(wp_opt wp_coding_agents_posture | tr -d '[:space:]')"
case "$SOURCE_MODE" in
  managed) SOURCE_MODE=owned ;;
  engineering) SOURCE_MODE=workspace ;;
esac

_say "wp-coding-agents verify"
_say "  site:        $SITE_PATH"
_say "  source mode: ${SOURCE_MODE:-<unset>}"

# ---------------------------------------------------------------------------
# Seam 0: workspace declarations must point at native repositories and match
# the runtime permission surface that makes them editable.
# ---------------------------------------------------------------------------

section "workspace repository agreement"

if [ "$SOURCE_MODE" != "workspace" ]; then
  skip "not a workspace-mode install"
else
  PROFILE="$SITE_PATH/.wp-coding-agents/installation-profile"
  DECLARED_WORKSPACE_REPOSITORIES=""
  if [ -f "$PROFILE" ]; then
    DECLARED_WORKSPACE_REPOSITORIES="$(awk -F= '$1 == "workspace_repositories" { print substr($0, index($0, "=") + 1); exit }' "$PROFILE")"
  fi

  if [ -z "$DECLARED_WORKSPACE_REPOSITORIES" ]; then
    skip "no declared workspace repositories — cannot validate repository authority"
  elif [ ! -f "$SITE_PATH/opencode.json" ]; then
    fail "workspace repositories are declared but opencode.json is missing — the runtime has no configured repository access"
  else
    while IFS= read -r repository; do
      [ -n "$repository" ] || continue
      if ! git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        fail "declared workspace repository $repository is not a reachable Git checkout"
        continue
      fi
      if python3 - "$SITE_PATH/opencode.json" "$repository" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1]))
rules = data.get("permission", {}).get("external_directory", {})
sys.exit(0 if rules.get(sys.argv[2] + "/**") == "allow" else 1)
PY
      then
        pass "declared repository $repository is a Git checkout and OpenCode may access it"
      else
        fail "declared repository $repository is a Git checkout but opencode.json does not allow it — native edits and Git cannot reach the declared authority"
      fi
    done < <(printf '%s\n' "$DECLARED_WORKSPACE_REPOSITORIES" | tr ' ' '\n')
  fi
fi

# ---------------------------------------------------------------------------
# Seam 1: the recorded set, the manifest, and the permissions must agree
# ---------------------------------------------------------------------------

section "owned set agreement"

if [ "$SOURCE_MODE" != "owned" ]; then
  skip "not an owned-mode install — no owned set to agree about"
else
  RECORDED="$(wp_opt wp_coding_agents_owned_sources | sed '/^[[:space:]]*$/d' | sort)"
  [ -n "$RECORDED" ] || RECORDED="$(wp_opt wp_coding_agents_managed_sources | sed '/^[[:space:]]*$/d' | sort)"

  SITE_KEY="$(basename "$SITE_PATH")"
  MANIFEST="${SOURCE_POLICY_MANIFEST_ROOT:-/var/lib/wp-coding-agents}/$SITE_KEY/owned-sources"

  if [ -z "$RECORDED" ]; then
    fail "owned mode records no sources — the agent has no editable source at all"
  else
    pass "recorded owned sources: $(printf '%s' "$RECORDED" | tr '\n' ' ')"
  fi

  if [ ! -f "$MANIFEST" ]; then
    fail "manifest missing at $MANIFEST — out-of-band capture cannot learn the editable set"
  else
    MANIFEST_SET="$(sed '/^[[:space:]]*$/d' "$MANIFEST" | sort)"
    if [ "$MANIFEST_SET" = "$RECORDED" ]; then
      pass "manifest agrees with the recorded set"
    else
      fail "manifest disagrees with the recorded set — capture and permissions would diverge
          recorded: $(printf '%s' "$RECORDED" | tr '\n' ' ')
          manifest: $(printf '%s' "$MANIFEST_SET" | tr '\n' ' ')"
    fi

    # The reader is a deliberately unprivileged identity that cannot reach the
    # database. A manifest it cannot read is the same as no manifest.
    MODE="$(file_mode "$MANIFEST")"
    case "$MODE" in
      *4|*5|*6|*7) pass "manifest is world-readable ($MODE) — the capture identity can read it" ;;
      *) fail "manifest mode $MODE is not world-readable — the capture identity cannot read it" ;;
    esac

    case "$MANIFEST" in
      "$SITE_PATH"/*) fail "manifest lives inside the web root — it is fetchable over HTTP" ;;
      *) pass "manifest lives outside the web root" ;;
    esac
  fi

  # The permission surface has to grant exactly what was declared. Declared but
  # denied is an agent that cannot do its job; denied but allowed is an agent
  # editing something nothing captures.
  OPENCODE_JSON="$SITE_PATH/opencode.json"
  if [ ! -f "$OPENCODE_JSON" ]; then
    skip "no opencode.json — cannot compare permissions"
  else
    ALLOWED="$(python3 - "$OPENCODE_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
rules = d.get("permission", {}).get("edit", {})
if not isinstance(rules, dict):
    sys.exit(0)
for pattern, action in rules.items():
    if action == "allow" and pattern.endswith("/**"):
        print(pattern[:-3])
PY
)"
    ALLOWED="$(printf '%s' "$ALLOWED" | sed '/^[[:space:]]*$/d' | sort)"
    if [ "$ALLOWED" = "$RECORDED" ]; then
      pass "permission.edit allows exactly the declared set"
    else
      fail "permission.edit disagrees with the declared set
          declared: $(printf '%s' "$RECORDED" | tr '\n' ' ')
          allowed:  $(printf '%s' "$ALLOWED" | tr '\n' ' ')"
    fi

    # These denies are what keep the agent off a payment gateway. Their absence
    # is the failure worth waking up for.
    for root in "wp-content/plugins/**" "wp-content/themes/**" "wp-admin/**" "wp-includes/**" "wp-config.php"; do
      if python3 - "$OPENCODE_JSON" "$root" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission", {}).get("edit", {}).get(sys.argv[2]) == "deny" else 1)
PY
      then
        pass "denied: $root"
      else
        fail "NOT denied: $root — third-party code and core are writable by the edit tool"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Seam 2: the service identity must be internally coherent
# ---------------------------------------------------------------------------

section "service identity coherence"

UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
UNITS_CHECKED=0
for unit in "$UNIT_DIR"/kimaki*.service "$UNIT_DIR"/datamachine-worker.service; do
  [ -f "$unit" ] || continue
  UNITS_CHECKED=$((UNITS_CHECKED + 1))
  name="$(basename "$unit")"
  u_user="$(awk -F= '/^User=/ {print $2; exit}' "$unit")"
  [ -n "$u_user" ] || continue
  u_home="$(getent passwd "$u_user" 2>/dev/null | cut -d: -f6)"
  [ -n "$u_home" ] || u_home="/home/$u_user"
  [ "$u_user" = "root" ] && u_home="/root"

  env_home="$(awk -F= '/^Environment=HOME=/ {print $3; exit}' "$unit")"
  if [ -z "$env_home" ]; then
    skip "$name declares no HOME"
  elif [ "$env_home" = "$u_home" ]; then
    pass "$name: User=$u_user and HOME=$env_home agree"
  else
    fail "$name: User=$u_user but HOME=$env_home — the service cannot read its own home"
  fi

  # Any value pointing into a home that is not this user's is left over from an
  # identity that no longer exists.
  while IFS= read -r line; do
    value="${line#Environment=*=}"
    case "$value" in
      /root/*|/home/*)
        case "$value" in
          "$u_home"/*|"$u_home") ;;
          *) fail "$name: '${line%%=*}=${line#Environment=}' points outside ${u_user}'s home" ;;
        esac
        ;;
    esac
  done < <(grep '^Environment=' "$unit" 2>/dev/null | grep -vE '^Environment=(PATH|HOME)=')
done

[ "$UNITS_CHECKED" -eq 0 ] && skip "no agent systemd units on this host"

# ---------------------------------------------------------------------------
# Seam 3: the pieces owned mode requires must actually be installed
# ---------------------------------------------------------------------------

section "owned-mode components"

if [ "$SOURCE_MODE" != "owned" ]; then
  skip "not an owned-mode install"
else
  for mu in wp-coding-agents-source-reconcile wp-coding-agents-runtime-guard; do
    if [ -f "$SITE_PATH/wp-content/mu-plugins/$mu.php" ]; then
      pass "$mu is installed"
    else
      fail "$mu is missing — owned mode is not fully applied"
    fi
  done

  # opencode.json must stay writable by the runtime user, or the reactive
  # reconcile updates the option and the manifest while the permission surface
  # silently freezes. That is not hypothetical: file_put_contents()+rename()
  # creates a new inode owned by whoever ran it, so a reconcile run as root left
  # this root:root 0644 and every later one failed without saying so.
  if [ -f "$OPENCODE_JSON" ]; then
    OJ_MODE="$(file_mode "$OPENCODE_JSON")"
    case "$OJ_MODE" in
      *[67]*) pass "opencode.json is group-writable ($OJ_MODE) — the runtime can update permissions" ;;
      *) fail "opencode.json mode $OJ_MODE is not group-writable — the reactive reconcile cannot update the permission surface" ;;
    esac
  fi

  # A reconcile that cannot write is a reconcile that reports success and
  # changes nothing.
  MANIFEST_DIR="${SOURCE_POLICY_MANIFEST_ROOT:-/var/lib/wp-coding-agents}/$(basename "$SITE_PATH")"
  if [ -d "$MANIFEST_DIR" ]; then
    # Answering this requires becoming another user, which requires root. When
    # that is impossible the invariant has not been shown to hold and must be
    # reported as unchecked — not as a failure, which would cry wolf on every
    # unprivileged run, and not as a pass, which is how a checker becomes
    # decoration.
    if [ "$(id -u)" -ne 0 ] || ! id -u www-data >/dev/null 2>&1; then
      skip "cannot test manifest writability without root and a www-data account"
    elif su -s /bin/bash www-data -c "test -w '$MANIFEST_DIR'" 2>/dev/null; then
      pass "the web user can write the manifest directory"
    else
      fail "www-data cannot write $MANIFEST_DIR — the reactive reconcile updates the option and leaves capture reading a stale file"
    fi
  fi
fi

# ---------------------------------------------------------------------------

section "result"
_say "  $PASSED passed, $FAILED failed, $SKIPPED skipped"

if [ "$JSON" = true ]; then
  printf '{"passed":%d,"failed":%d,"skipped":%d,"findings":' "$PASSED" "$FAILED" "$SKIPPED"
  printf '%s' "$FINDINGS" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().split("\n") if l.strip()]))'
  printf '}\n'
fi

[ "$FAILED" -eq 0 ] || exit 1
exit 0
