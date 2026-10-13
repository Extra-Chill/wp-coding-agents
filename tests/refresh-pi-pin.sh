#!/bin/bash
# tests/refresh-pi-pin.sh — the Pi pin follows the newest release within its
# major version, never moves backwards, and never crosses a major by itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# A scratch copy of the repo layout the script reads and writes.
mkdir -p "$TMP/repo/scripts" "$TMP/repo/bridges/roadie" "$TMP/bin"
cp "$SCRIPT_DIR/scripts/refresh-pi-pin.sh" "$TMP/repo/scripts/"
PIN="$TMP/repo/bridges/roadie/pi-version"

# Fake npm: `npm view <pkg> version` answers FAKE_VERSION, or fails when unset.
cat > "$TMP/bin/npm" <<'FAKE'
#!/bin/bash
[ "$1" = view ] && [ "$3" = version ] || exit 2
[ -n "${FAKE_VERSION:-}" ] || exit 1
printf '%s\n' "$FAKE_VERSION"
FAKE
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"

run() { "$TMP/repo/scripts/refresh-pi-pin.sh" > "$TMP/out" 2> "$TMP/err"; }
pin() { tr -d '[:space:]' < "$PIN"; }

echo "==> newer release in the same major moves the pin"
echo 1.2.0 > "$PIN"
FAKE_VERSION=1.3.1 run
check $? "exits 0"
[ "$(pin)" = 1.3.1 ]; check $? "pin is 1.3.1"
[ "$(cat "$TMP/out")" = 1.3.1 ]; check $? "prints the new pin"

echo "==> current pin is a no-op"
FAKE_VERSION=1.3.1 run
check $? "exits 0"
[ "$(pin)" = 1.3.1 ]; check $? "pin unchanged"

echo "==> a new major is refused"
FAKE_VERSION=2.0.0 run
[ $? -ne 0 ]; check $? "exits non-zero"
[ "$(pin)" = 1.3.1 ]; check $? "pin unchanged"
grep -q "new major version" "$TMP/err"; check $? "explains the refusal"

echo "==> an older release never downgrades the pin"
FAKE_VERSION=1.2.9 run
[ $? -ne 0 ]; check $? "exits non-zero"
[ "$(pin)" = 1.3.1 ]; check $? "pin unchanged"

echo "==> version order is numeric, not lexical"
echo 1.9.0 > "$PIN"
FAKE_VERSION=1.10.0 run
check $? "exits 0"
[ "$(pin)" = 1.10.0 ]; check $? "1.10.0 is newer than 1.9.0"

echo "==> an unresolvable or malformed release leaves the pin alone"
FAKE_VERSION="" run
[ $? -ne 0 ]; check $? "registry failure exits non-zero"
FAKE_VERSION="1.11.0-beta.1" run
[ $? -ne 0 ]; check $? "prerelease exits non-zero"
[ "$(pin)" = 1.10.0 ]; check $? "pin unchanged"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: tests/refresh-pi-pin.sh ($FAIL failed, $PASS passed)"
  exit 1
fi
echo "PASS: tests/refresh-pi-pin.sh ($PASS assertions)"
