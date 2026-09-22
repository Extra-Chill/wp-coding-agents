#!/bin/bash
# tests/upgrade-help.sh — `./upgrade.sh --help` must print and exit, never hang.
#
# WHY THIS EXISTS
#
# upgrade.sh:208 used an unquoted heredoc (`cat << HELP`) to print the usage
# banner. An unquoted delimiter enables parameter expansion AND command
# substitution inside the body. The help text itself contained a backtick
# pair around "wp server" as prose ("...backed by `wp server`."), which bash
# happily executed as a command substitution — starting a blocking PHP dev
# server and hanging --help forever (#620). --help is the documented source
# of truth for this script's flags; a version of it that never returns is
# worse than no --help at all.
#
# This test runs --help under a hard timeout so a regression fails loudly
# instead of hanging the test runner, and asserts the banner still renders
# correctly for the two lines that DO need a runtime value substituted after
# the heredoc (the migration default user) or intentionally shown as a
# literal placeholder ($KIMAKI_DATA_DIR) rather than expanded.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

FAILED=0

echo "==> ./upgrade.sh --help terminates and exits 0"
set +e
timeout 10 bash "$SCRIPT_DIR/upgrade.sh" --help > "$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -eq 124 ]; then
  echo "  FAIL --help hung and was killed by timeout (this is exactly #620)"
  FAILED=1
elif [ "$rc" -ne 0 ]; then
  echo "  FAIL --help exited $rc, expected 0"
  cat "$OUT"
  FAILED=1
else
  echo "  ok   exited 0"
fi

echo "==> usage banner renders"
if ! grep -q "wp-coding-agents upgrade script" "$OUT"; then
  echo "  FAIL usage banner header missing"
  FAILED=1
else
  echo "  ok   banner present"
fi

echo "==> the wp server backticks render as literal text, not a command result"
if ! grep -qF '`wp server`' "$OUT"; then
  echo "  FAIL literal \`wp server\` text missing — heredoc expansion may have eaten it"
  FAILED=1
else
  echo "  ok   literal text present"
fi
if grep -qE "PHP .* Development Server" "$OUT"; then
  echo "  FAIL a PHP dev server banner leaked into --help output — wp server ran"
  FAILED=1
else
  echo "  ok   no dev server output"
fi

echo "==> migration default user still resolves to a real value"
if ! grep -q "(default: opencode)\." "$OUT"; then
  echo "  FAIL expected literal 'opencode' substituted for the migration default user"
  FAILED=1
else
  echo "  ok   default user resolved"
fi

echo "==> KIMAKI_DATA_DIR placeholder renders as a clean literal (no stray backslash)"
if ! grep -qF '$KIMAKI_DATA_DIR/kimaki-config/plugins' "$OUT"; then
  echo "  FAIL expected literal \$KIMAKI_DATA_DIR placeholder line"
  FAILED=1
else
  echo "  ok   placeholder renders cleanly"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAIL: tests/upgrade-help.sh"
  exit 1
fi
echo "PASS: tests/upgrade-help.sh"
