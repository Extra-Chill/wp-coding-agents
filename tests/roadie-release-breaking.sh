#!/bin/bash
# tests/roadie-release-breaking.sh — the release-range breaking detector flags
# the markers the pin refresh must not push to main, and stays quiet otherwise.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/bin/bash
case "$2" in
  */compare/*)
    [ -n "${FAKE_COMPARE:-}" ] || exit 1
    printf '%b' "$FAKE_COMPARE\n"
    ;;
  */releases/tags/*)
    if [ -n "${FAKE_NOTES:-}" ]; then printf '%s\n' "$FAKE_NOTES"; else exit 1; fi
    ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

run() { ./scripts/roadie-release-breaking.sh "$@" > "$TMP/out" 2> "$TMP/err"; }
reasons() { cat "$TMP/out"; }

echo "==> usage and malformed input"
run
[ $? -ne 0 ]; check $? "no arguments exits 2"
run not-a-version 1.0.0
[ $? -ne 0 ]; check $? "malformed version exits 2"

echo "==> breaking commit subject (the #731 replay)"
# v0.58.2 -> v0.60.0 carried roadie#200's `feat!:` — the incident bump.
FAKE_COMPARE="feat!: Pi is the default agent backend (#200)

Some body.

release: v0.59.0" FAKE_NOTES="## What's Changed
* release: v0.60.0" run 0.58.2 0.60.0
check $? "breaking subject exits 0"
reasons | grep -q "feat!: Pi is the default agent backend"; check $? "reason names the breaking commit"

echo "==> BREAKING CHANGE footer"
FAKE_COMPARE="feat: add thing

BREAKING CHANGE: the config file moved" FAKE_NOTES="release: v1.0.0" run 1.0.0 1.1.0
check $? "footer exits 0"

echo "==> breaking marker in the target release notes"
FAKE_COMPARE="feat: quiet change" FAKE_NOTES="### ⚠ BREAKING CHANGES
* Pi is the only agent backend" run 1.0.0 1.1.0
check $? "release-note marker exits 0"

echo "==> a minor bump while Roadie is 0.x is breaking on its own"
FAKE_COMPARE="feat: quiet change" FAKE_NOTES="release: v0.61.0" run 0.60.0 0.61.0
check $? "0.x minor bump exits 0"
reasons | grep -q "minor bump in 0.x"; check $? "reason names the minor bump"

echo "==> a quiet patch release is not breaking"
FAKE_COMPARE="fix: a bug" FAKE_NOTES="release: v0.60.1" run 0.60.0 0.60.1
[ $? -ne 0 ]; check $? "patch bump exits 1"

echo "==> a quiet minor release after 1.x is not breaking"
FAKE_COMPARE="feat: a feature" FAKE_NOTES="release: v1.1.0" run 1.0.0 1.1.0
[ $? -ne 0 ]; check $? "post-1.0 minor bump exits 1"

echo "==> scope breaking marker is caught"
FAKE_COMPARE="feat(backend)!: switch the default" FAKE_NOTES="release: v0.60.0" run 0.59.0 0.60.0
check $? "scoped !: exits 0"

echo "==> API failure is treated as breaking"
FAKE_COMPARE="" FAKE_NOTES="" run 1.0.0 1.1.0
check $? "undecidable range exits 0"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
