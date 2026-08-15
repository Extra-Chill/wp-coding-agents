#!/bin/bash
# tests/ci-coverage.sh — every test in tests/ is actually run by CI.
#
# WHY THIS EXISTS
#
# On 2026-08-05, 19 of 42 test files — nearly half the suite — were present in
# the repo and referenced nowhere in .github/workflows/shell.yml. They were only
# ever run by someone remembering to run them by hand.
#
# The consequence was not theoretical. #334 changed how the Kimaki lock port
# reaches a systemd unit, updated tests/kimaki-multi-instance.sh to match,
# merged with 20/20 checks green, and left that test failing on main — because
# it was one of the 19. CI reported green over red, and the only reason anyone
# noticed was an unrelated full-suite run.
#
# A workflow that lists jobs by hand fails this way silently and permanently: the
# person adding a test is the same person who has to remember to wire it, and
# nothing complains when they don't. This test makes the omission loud, which is
# the only property that actually holds over time.
#
# It deliberately checks for the test NAME anywhere in the workflow rather than
# an exact `./tests/<name>.sh` invocation, so a matrix entry, a composite job, or
# a future restructuring all still satisfy it. The claim being made is "CI knows
# about this file", not "CI invokes it in one particular way".
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

WORKFLOW=".github/workflows/shell.yml"
FAILED=0

if [ ! -f "$WORKFLOW" ]; then
  echo "  FAIL $WORKFLOW not found"
  exit 1
fi

# Tests deliberately not wired into CI, each with the reason it cannot run there.
# Adding a name here is a decision that should be visible in review; an empty
# list is the healthy state.
#
#   (none)
#
EXCLUDED=""

is_excluded() {
  local name="$1" e
  for e in $EXCLUDED; do
    [ "$name" = "$e" ] && return 0
  done
  return 1
}

echo "ci-coverage: every tests/*.sh is referenced by $WORKFLOW"

workflow_text="$(cat "$WORKFLOW")"
missing=""

for path in tests/*.sh; do
  name="$(basename "$path" .sh)"
  if is_excluded "$name"; then
    echo "  skip $name (documented exclusion)"
    continue
  fi
  case "$workflow_text" in
    *"$name"*) ;;
    *)
      missing="$missing $name"
      FAILED=$((FAILED + 1))
      ;;
  esac
done

if [ -n "$missing" ]; then
  echo "  FAIL these tests exist but CI never runs them:"
  for name in $missing; do
    echo "         tests/$name.sh"
  done
  echo ""
  echo "  Add a job to $WORKFLOW, or add the name to EXCLUDED in this file"
  echo "  with the reason it cannot run in CI."
else
  echo "  ok   all $(ls tests/*.sh | wc -l | tr -d ' ') shell tests are referenced"
fi

# Non-shell suites are invoked directly by their own jobs; assert the ones that
# exist stay wired, since they are the easiest to lose in a restructure.
for other in tests/dm-agent-sync.mjs tests/setup-profile-compiler.mjs tests/smoke-cli-transport.php; do
  [ -e "$other" ] || continue
  case "$workflow_text" in
    *"$(basename "$other")"*) echo "  ok   $(basename "$other") is referenced" ;;
    *)
      echo "  FAIL $other exists but CI never runs it"
      FAILED=$((FAILED + 1))
      ;;
  esac
done

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "ci-coverage: all assertions passed"
else
  echo "ci-coverage: $FAILED assertion(s) failed"
  exit 1
fi
