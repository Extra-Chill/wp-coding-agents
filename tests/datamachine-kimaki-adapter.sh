#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT/bridges/kimaki/bin/datamachine-kimaki"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_KIMAKI="$TMP/kimaki-real"
CALL_LOG="$TMP/calls.log"

cat > "$REAL_KIMAKI" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$CALL_LOG"
SH
chmod +x "$REAL_KIMAKI"

export DATAMACHINE_REAL_KIMAKI="$REAL_KIMAKI"
export CALL_LOG

assert_args() {
  python3 - "$CALL_LOG" "$@" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2:]
with open(path, 'rb') as handle:
    raw = handle.read()
actual = [part.decode() for part in raw.split(b'\0') if part]
if actual != expected:
    raise SystemExit(f"expected {expected!r}, got {actual!r}")
PY
}

assert_fails_without_call() {
  rm -f "$CALL_LOG"
  if "$ADAPTER" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "expected adapter failure for: $*" >&2
    exit 1
  fi
  if [[ -f "$CALL_LOG" ]]; then
    echo "real kimaki should not have been called for: $*" >&2
    exit 1
  fi
}

"$ADAPTER" send --prompt hi --agent opencode
assert_args send --prompt hi --agent build

"$ADAPTER" send --prompt hi --agent plan
assert_args send --prompt hi --agent build

"$ADAPTER" send --prompt hi --agent=general
assert_args send --prompt hi --agent build

"$ADAPTER" send --prompt hi --cwd /tmp/elsewhere
assert_args send --prompt hi

"$ADAPTER" send --prompt hi --cwd=/tmp/elsewhere --agent opencode
assert_args send --prompt hi --agent build

"$ADAPTER" send --prompt hi --agent --model anthropic/test
assert_args send --prompt hi --agent build --model anthropic/test

"$ADAPTER" send --prompt hi --cwd --model anthropic/test
assert_args send --prompt hi --model anthropic/test

assert_fails_without_call send --prompt hi --worktree feature-x
grep -q 'Native Kimaki worktrees are disabled' "$TMP/stderr"

"$ADAPTER" session list --project /tmp/site
assert_args session list --project /tmp/site

echo "OK: datamachine-kimaki adapter normalizes Kimaki send flags"
