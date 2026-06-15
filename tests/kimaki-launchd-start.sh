#!/bin/bash
# tests/kimaki-launchd-start.sh — verifies the managed launchd entrypoint
# runs wp-coding-agents preflight hooks without touching real processes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/data/kimaki-config"

cat > "$TMP/bin/pkill" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$TEST_TMP/pkill.log"
exit 0
SH
chmod +x "$TMP/bin/pkill"

cat > "$TMP/data/kimaki-config/post-upgrade.sh" <<'SH'
#!/bin/sh
printf 'post-upgrade\n' > "$TEST_TMP/post-upgrade.log"
exit 17
SH
chmod +x "$TMP/data/kimaki-config/post-upgrade.sh"

cat > "$TMP/bin/kimaki" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$TEST_TMP/kimaki.log"
SH
chmod +x "$TMP/bin/kimaki"

TEST_TMP="$TMP" \
PATH="$TMP/bin:/usr/bin:/bin" \
KIMAKI_DATA_DIR="$TMP/data" \
  "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" "$TMP/bin/kimaki" --data-dir "$TMP/data" --auto-restart

if ! grep -q -- '-TERM -f opencode-ai/bin/.*serve' "$TMP/pkill.log"; then
  echo "FAIL: launchd-start did not reap stale opencode serve processes"
  cat "$TMP/pkill.log" 2>/dev/null || true
  exit 1
fi

if ! grep -q '^post-upgrade$' "$TMP/post-upgrade.log"; then
  echo "FAIL: launchd-start did not run post-upgrade.sh"
  exit 1
fi

if ! grep -q -- "--data-dir $TMP/data --auto-restart" "$TMP/kimaki.log"; then
  echo "FAIL: launchd-start did not exec kimaki with original arguments"
  cat "$TMP/kimaki.log" 2>/dev/null || true
  exit 1
fi

echo "PASS: tests/kimaki-launchd-start.sh"
