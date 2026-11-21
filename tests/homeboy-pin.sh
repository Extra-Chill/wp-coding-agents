#!/bin/bash
# tests/homeboy-pin.sh — Homeboy is a pinned dependency, converged on upgrade.
#
# Like Roadie, the Homeboy release a host runs is the one this install pins in
# services/homeboy-version, refreshed by the homeboy.json dependency_stack. The
# managed binary is moved with Homeboy's own `upgrade --version`, as the service
# user, and a Homeboy that cannot move (or defers its daemon swap while a cook
# holds a lease) never fails the upgrade.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/homeboy.sh"

SCRIPT_DIR="$ROOT"
log() { printf 'LOG %s\n' "$*" >> "$TMP/out.log"; }
warn() { printf 'WARN %s\n' "$*" >> "$TMP/out.log"; }
DRY_RUN=false

# Seams: the managed-bin gates and the one command runner (which already drops
# to the service user; tests/homeboy-service-identity.sh owns that contract).
MANAGED=true
homeboy_uses_service_owned_bin() { [ "$MANAGED" = true ]; }
homeboy_service_bin_ready() { [ "$MANAGED" = true ]; }
# Fake Homeboy: --version prints $TMP/installed; upgrade records its argv and
# then behaves per $MODE.
homeboy_run() {
  case "$1" in
    --version) printf 'homeboy %s+0123abcd\n' "$(cat "$TMP/installed")" ;;
    upgrade)
      printf '%s\n' "$*" >> "$TMP/upgrade.calls"
      case "$MODE" in
        ok) printf '%s\n' "${3#v}" > "$TMP/installed"; printf '{"success":true}\n' ;;
        deferred) printf '%s\n' "${3#v}" > "$TMP/installed"
          printf '{"data":{"daemon_pending_restart":{"reason":"pid 1 is still serving lease"}}}\n'; return 1 ;;
        installed-nonzero) printf '%s\n' "${3#v}" > "$TMP/installed"; return 4 ;;
        broken) printf 'network error\n' >&2; return 1 ;;
      esac ;;
  esac
}
PIN="$(tr -d '[:space:]' < "$ROOT/services/homeboy-version")"
reset() { rm -f "$TMP/upgrade.calls" "$TMP/out.log"; printf '%s\n' "$1" > "$TMP/installed"; MODE="${2:-ok}"; }

echo "==> the pin"
[[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; check $? "services/homeboy-version is a bare semver like roadie-version ($PIN)"
[ "$(homeboy_pinned_version)" = "$PIN" ]; check $? "homeboy_pinned_version reads it"
python3 - "$ROOT/homeboy.json" <<'PY'
import json, sys
stack = json.load(open(sys.argv[1]))["dependency_stack"]
hb = [e for e in stack if e.get("upstream") == "homeboy"]
assert len(hb) == 1, hb
e = hb[0]
assert e["downstream"] == "wp-coding-agents"
assert e["source"] == {"github_release": "Extra-Chill/homeboy"}
assert e["lock"] == {"kind": "version-file", "path": "services/homeboy-version"}
PY
check $? "homeboy.json dependency_stack refreshes services/homeboy-version from Homeboy releases"
( HOMEBOY_VERSION_FILE="$TMP/none"; homeboy_pinned_version >/dev/null ); [ $? -ne 0 ]; check $? "a missing pin is reported, not guessed"
printf 'v1.2\n' > "$TMP/badpin"
( HOMEBOY_VERSION_FILE="$TMP/badpin"; homeboy_pinned_version >/dev/null ); [ $? -ne 0 ]; check $? "a malformed pin is rejected"

echo "==> converge"
reset "$PIN"; homeboy_converge_pinned_version; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$TMP/upgrade.calls" ]; check $? "already at the pin: no upgrade"
[ "$(homeboy_installed_version)" = "$PIN" ]; check $? "installed version drops the +build suffix"

reset 0.1.0 ok; homeboy_converge_pinned_version; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$TMP/upgrade.calls")" = "upgrade --version v$PIN" ]; check $? "behind: runs exactly 'homeboy upgrade --version v<pin>'"
grep -q "LOG Homeboy upgraded to $PIN" "$TMP/out.log"; check $? "a landed upgrade is logged"

reset 99.0.0 ok; homeboy_converge_pinned_version
[ "$(cat "$TMP/upgrade.calls")" = "upgrade --version v$PIN" ]; check $? "ahead (moved by hand): converged back to the reviewed pin"

reset 0.1.0 deferred; homeboy_converge_pinned_version; rc=$?
[ "$rc" -eq 0 ] && grep -q "WARN .*daemon restart deferred" "$TMP/out.log"; check $? "daemon busy with a lease: deferred warning, not a failure"
grep -q -- "--force" "$TMP/upgrade.calls"; [ $? -ne 0 ]; check $? "a deferral is never forced"

reset 0.1.0 installed-nonzero; homeboy_converge_pinned_version; rc=$?
[ "$rc" -eq 0 ] && grep -q "WARN .*installed but its upgrade exited 4" "$TMP/out.log"; check $? "landed with a non-zero exit: warned, non-fatal"

reset 0.1.0 broken; homeboy_converge_pinned_version; rc=$?
[ "$rc" -eq 0 ] && grep -q "WARN .*did not land (installed: 0.1.0" "$TMP/out.log"; check $? "upgrade failure: warned, non-fatal, retried next upgrade"

reset 0.1.0 ok; ( DRY_RUN=true; homeboy_converge_pinned_version ) > "$TMP/dry.out"
[ ! -e "$TMP/upgrade.calls" ] && grep -q "Would upgrade Homeboy 0.1.0 -> $PIN" "$TMP/dry.out"; check $? "dry run: reports, changes nothing"

reset 0.1.0 ok; ( HOMEBOY_VERSION_FILE="$TMP/none"; homeboy_converge_pinned_version ); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$TMP/upgrade.calls" ] && grep -q "WARN Homeboy pin is missing" "$TMP/out.log"; check $? "no pin: leaves Homeboy alone, warns"

reset 0.1.0 ok; ( MANAGED=false; homeboy_converge_pinned_version ); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$TMP/upgrade.calls" ]; check $? "local, external, or root installs (no service-owned bin): untouched"

echo "==> wiring"
grep -A1 '^homeboy_provision_service_bin$' "$ROOT/upgrade.sh" | grep -q '^homeboy_converge_pinned_version$'; check $? "upgrade.sh converges right after provisioning the managed bin"
grep -A1 '^    homeboy_provision_service_bin$' "$ROOT/setup.sh" | grep -q 'homeboy_converge_pinned_version'; check $? "setup.sh converges right after provisioning the managed bin"
grep -q 'services/homeboy-version' "$ROOT/verify.sh"; check $? "verify.sh checks the managed binary against the pin"

echo
if [ "$FAIL" -gt 0 ]; then echo "FAIL: $FAIL assertion(s)"; exit 1; fi
echo "PASS: tests/homeboy-pin.sh ($PASS assertions)"
