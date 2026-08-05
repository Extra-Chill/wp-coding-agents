#!/bin/bash
# tests/service-identity-defaults.sh — owned mode defaults to non-root (#327).
#
# The claim in #327 is that every install, including the managed ones, runs an
# unrestricted root shell — and that the edit denies shipped in #314/#318/#322
# do not change that, because `permission.edit` gates the runtime's edit tool
# while `bash` is a separate, unset, therefore allowed key. A root service
# reaches every denied path through `bash -c`, `wp eval`, or PHP. The service
# user is the only lever in that list the kernel enforces.
#
# What must hold:
#
#   1. A fresh owned install lands on a non-root service user, with the service
#      home and the Kimaki data dir moved to match. Flipping RUN_AS_ROOT alone
#      would leave SERVICE_USER and the data dir pointing at /root — the
#      half-applied identity behind both #204 and #93.
#   2. An operator who said --root or --non-root is not second-guessed.
#   3. Workspace mode is untouched. That install belongs to a developer who
#      chose it; changing its default here would be an unrelated behaviour
#      change smuggled in under a security fix.
#   4. Re-derivation is idempotent and does not clobber an explicit
#      --kimaki-data-dir.
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
    *) echo "  FAIL $name (missing: $needle)"; FAILED=$((FAILED + 1)) ;;
  esac
}

# Evaluate the default in a subshell and report the resulting identity.
# Args: SOURCE_MODE SERVICE_USER_FORCED LOCAL_MODE RUN_AS_ROOT [KIMAKI_DATA_DIR]
identity_after_default() {
  (
    SOURCE_MODE="$1"
    SERVICE_USER_FORCED="$2"
    LOCAL_MODE="$3"
    RUN_AS_ROOT="$4"
    KIMAKI_DATA_DIR_EXPLICIT=false
    if [ -n "${5:-}" ]; then
      KIMAKI_DATA_DIR="$5"
      KIMAKI_DATA_DIR_EXPLICIT=true
    fi
    log() { :; }
    # shellcheck disable=SC1091
    source lib/detect.sh
    detect_service_identity
    detect_apply_source_mode_identity_default
    printf '%s|%s|%s|%s' "$RUN_AS_ROOT" "$SERVICE_USER" "$SERVICE_HOME" "$KIMAKI_DATA_DIR"
  )
}

echo "owned mode defaults to a non-root service user"

assert_eq "$(identity_after_default owned false false true)" \
  "false|opencode|/home/opencode|/home/opencode/.kimaki" \
  "fresh owned install lands fully on the opencode identity"

echo ""
echo "the operator's explicit choice wins"

# --root: SERVICE_USER_FORCED=true with RUN_AS_ROOT=true.
assert_eq "$(identity_after_default owned true false true)" \
  "true|root|/root|/root/.kimaki" \
  "--root is not overridden by the owned default"

# --non-root: already non-root, nothing to do.
assert_eq "$(identity_after_default owned true false false)" \
  "false|opencode|/home/opencode|/home/opencode/.kimaki" \
  "--non-root is left as it is"

echo ""
echo "workspace mode is untouched"

assert_eq "$(identity_after_default workspace false false true)" \
  "true|root|/root|/root/.kimaki" \
  "workspace mode keeps its existing root default"

assert_eq "$(identity_after_default workspace false false false)" \
  "false|opencode|/home/opencode|/home/opencode/.kimaki" \
  "workspace mode still honours an explicit non-root"

echo ""
echo "local installs are unaffected"

# LOCAL_MODE has no systemd and no service user to create; the identity is
# whoever is running the install.
local_result="$(identity_after_default owned false true true)"
assert_contains "$local_result" "$(whoami)" "local mode keeps the invoking user"

echo ""
echo "re-derivation is safe"

# Idempotence: applying the default twice must not drift.
once="$(identity_after_default owned false false true)"
twice="$(
  (
    SOURCE_MODE=owned SERVICE_USER_FORCED=false LOCAL_MODE=false RUN_AS_ROOT=true
    KIMAKI_DATA_DIR_EXPLICIT=false
    log() { :; }
    # shellcheck disable=SC1091
    source lib/detect.sh
    detect_service_identity
    detect_apply_source_mode_identity_default
    detect_apply_source_mode_identity_default
    detect_service_identity
    printf '%s|%s|%s|%s' "$RUN_AS_ROOT" "$SERVICE_USER" "$SERVICE_HOME" "$KIMAKI_DATA_DIR"
  )
)"
assert_eq "$twice" "$once" "applying the default repeatedly is idempotent"

# An explicit --kimaki-data-dir must survive the re-derivation. Without the
# guard, the second detect_service_identity call would silently relocate the
# operator's data dir to the new home.
assert_eq "$(identity_after_default owned false false true /srv/kimaki-data)" \
  "false|opencode|/home/opencode|/srv/kimaki-data" \
  "an explicit --kimaki-data-dir is not relocated"

# A caller that only exported KIMAKI_DATA_DIR, without the flag machinery, keeps
# the historical `${KIMAKI_DATA_DIR:-default}` behaviour rather than being
# silently relocated by the re-derivation.
legacy_env=$(
  (
    unset KIMAKI_DATA_DIR_EXPLICIT
    SOURCE_MODE=owned SERVICE_USER_FORCED=false LOCAL_MODE=false RUN_AS_ROOT=true
    KIMAKI_DATA_DIR=/opt/preset-data
    log() { :; }
    # shellcheck disable=SC1091
    source lib/detect.sh
    detect_service_identity
    printf '%s' "$KIMAKI_DATA_DIR"
  )
)
assert_eq "$legacy_env" "/opt/preset-data" "a bare exported KIMAKI_DATA_DIR is respected"

echo ""
echo "wiring"

# The default has to run after the source mode resolves and before the phases
# that branch on RUN_AS_ROOT, or it decides nothing.
apply_line=$(grep -n '^detect_apply_source_mode_identity_default' setup.sh | head -1 | cut -d: -f1)
mode_line=$(grep -n '^source_policy_resolve_mode' setup.sh | head -1 | cut -d: -f1)
user_line=$(grep -n '^  create_service_user' setup.sh | head -1 | cut -d: -f1)
perms_line=$(grep -n '^  setup_service_permissions' setup.sh | head -1 | cut -d: -f1)
if [ -n "$apply_line" ] && [ -n "$mode_line" ] && [ -n "$user_line" ] && [ -n "$perms_line" ] &&
   [ "$apply_line" -gt "$mode_line" ] && [ "$apply_line" -lt "$user_line" ] && [ "$apply_line" -lt "$perms_line" ]; then
  echo "  ok   setup.sh applies the default after the mode resolves and before it is used"
else
  echo "  FAIL setup.sh ordering wrong (apply=${apply_line:-?} mode=${mode_line:-?} user=${user_line:-?} perms=${perms_line:-?})"
  FAILED=$((FAILED + 1))
fi

# An EXISTING owned install must be advised, never flipped. Flipping it here
# would re-render the unit against an identity whose home holds none of the
# agent's state — the #93 footgun, arrived at from the other direction.
assert_contains "$(cat upgrade.sh)" "--migrate-non-root" \
  "upgrade.sh points an owned root install at the migration"
upgrade_owned_block=$(sed -n '/SOURCE_MODE" = "owned" \]/,/^fi/p' upgrade.sh)
if printf '%s' "$upgrade_owned_block" | grep -q 'RUN_AS_ROOT=false'; then
  echo "  FAIL upgrade.sh flips an existing owned install implicitly"
  FAILED=$((FAILED + 1))
else
  echo "  ok   upgrade.sh does not flip an existing install implicitly"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "service-identity-defaults: all assertions passed"
else
  echo "service-identity-defaults: $FAILED assertion(s) failed"
  exit 1
fi
