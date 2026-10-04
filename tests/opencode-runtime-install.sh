#!/bin/bash
# tests/opencode-runtime-install.sh — runtime_install keeps OpenCode at or
# above the version managed integrations require, instead of installing only
# when the binary is missing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS + 1)); else echo "  FAIL $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi
}

export DRY_RUN=false
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/opencode-subagents.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtimes/opencode.sh"
_opencode_register_runtime_signature() { :; }

STUB="$TMP/bin"
mkdir -p "$STUB"
# Stub opencode reports the version in $TMP/version; stub npm records its
# arguments and "upgrades" by writing the next version.
cat > "$STUB/opencode" <<SH
#!/bin/bash
[ "\${1:-}" = "--version" ] && cat "$TMP/version"
SH
cat > "$STUB/npm" <<SH
#!/bin/bash
echo "\$*" >> "$TMP/npm.log"
[ -f "$TMP/next" ] && cp "$TMP/next" "$TMP/version"
exit 0
SH
chmod +x "$STUB/opencode" "$STUB/npm"
export PATH="$STUB:$PATH"

reset() {
  printf '%s\n' "$1" > "$TMP/version"
  rm -f "$TMP/npm.log" "$TMP/next"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$TMP/next"
  return 0
}

echo "==> an OpenCode older than the required version is upgraded"
reset 1.14.33 1.18.29
OUT="$(runtime_install 2>&1)"
assert_eq "npm installs the latest opencode-ai" "install -g opencode-ai@latest" "$(cat "$TMP/npm.log" 2>/dev/null)"
assert_eq "the upgraded version is reported" "1" "$(printf '%s' "$OUT" | grep -c 'OpenCode installed: 1.18.29')"

echo "==> a current OpenCode is left alone"
reset "$OPENCODE_GENERAL_DISPATCH_MIN_VERSION"
runtime_install >/dev/null 2>&1
assert_eq "npm is not run" "" "$(cat "$TMP/npm.log" 2>/dev/null)"

echo "==> an unparseable version is never reinstalled on a guess"
reset "dev-build"
runtime_install >/dev/null 2>&1
assert_eq "npm is not run" "" "$(cat "$TMP/npm.log" 2>/dev/null)"

echo "==> an upgrade that does not take effect warns instead of failing"
reset 1.14.33 1.14.33
RC=0
OUT="$(runtime_install 2>&1)" || RC=$?
assert_eq "runtime_install still succeeds" "0" "$RC"
assert_eq "it warns that an older copy may shadow the upgrade" "1" "$(printf '%s' "$OUT" | grep -c 'may not be the npm global install')"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "opencode-runtime-install: all $PASS assertions passed"
else
  echo "opencode-runtime-install: $FAIL of $((PASS + FAIL)) assertions failed"
  exit 1
fi
