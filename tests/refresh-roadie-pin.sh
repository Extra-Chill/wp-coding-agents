#!/bin/bash
# tests/refresh-roadie-pin.sh — the Roadie pin follows the newest release,
# never moves backwards, and never points at a release setup cannot install.
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
cp "$SCRIPT_DIR/scripts/refresh-roadie-pin.sh" "$TMP/repo/scripts/"
PIN="$TMP/repo/bridges/roadie/roadie-version"

# Fake gh: answers releases/latest from FAKE_TAG and the tag's assets from FAKE_ASSETS.
cat > "$TMP/bin/gh" <<'FAKE'
#!/bin/bash
case "$2" in
  */releases/latest) [ -n "${FAKE_TAG:-}" ] || exit 1; printf '%s\n' "$FAKE_TAG" ;;
  */releases/tags/*) printf '%s\n' $FAKE_ASSETS ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

run() { "$TMP/repo/scripts/refresh-roadie-pin.sh" > "$TMP/out" 2> "$TMP/err"; }
pin() { tr -d '[:space:]' < "$PIN"; }

echo "==> newer release with its tarball moves the pin"
echo 0.38.0 > "$PIN"
FAKE_TAG=v0.38.2 FAKE_ASSETS="extrachill-roadie-0.38.2.tgz roadie-workspace-0.38.2.tgz" run
check $? "exits 0"
[ "$(pin)" = 0.38.2 ]; check $? "pin is 0.38.2"
[ "$(cat "$TMP/out")" = 0.38.2 ]; check $? "prints the new pin"

echo "==> current pin is a no-op"
FAKE_TAG=v0.38.2 FAKE_ASSETS="" run
check $? "exits 0 without asking for assets"
[ "$(pin)" = 0.38.2 ]; check $? "pin unchanged"

echo "==> release without the tarball is refused"
FAKE_TAG=v0.39.0 FAKE_ASSETS="roadie-workspace-0.39.0.tgz" run
[ $? -ne 0 ]; check $? "exits non-zero"
[ "$(pin)" = 0.38.2 ]; check $? "pin unchanged"

echo "==> an older release never downgrades the pin"
FAKE_TAG=v0.37.0 FAKE_ASSETS="extrachill-roadie-0.37.0.tgz" run
[ $? -ne 0 ]; check $? "exits non-zero"
[ "$(pin)" = 0.38.2 ]; check $? "pin unchanged"

echo "==> version order is numeric, not lexical"
echo 0.9.0 > "$PIN"
FAKE_TAG=v0.10.0 FAKE_ASSETS="extrachill-roadie-0.10.0.tgz" run
check $? "exits 0"
[ "$(pin)" = 0.10.0 ]; check $? "0.10.0 is newer than 0.9.0"

echo "==> a non-version tag or a failed lookup leaves the pin alone"
FAKE_TAG=nightly FAKE_ASSETS="" run
[ $? -ne 0 ]; check $? "non-version tag exits non-zero"
FAKE_TAG="" FAKE_ASSETS="" run
[ $? -ne 0 ]; check $? "failed lookup exits non-zero"
[ "$(pin)" = 0.10.0 ]; check $? "pin unchanged"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
