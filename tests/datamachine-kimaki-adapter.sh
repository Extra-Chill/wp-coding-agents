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

"$ADAPTER" send --prompt hi --agent opencode
assert_args send --prompt hi --agent opencode

"$ADAPTER" send --prompt hi --agent plan
assert_args send --prompt hi --agent plan

"$ADAPTER" send --prompt hi --agent=general
assert_args send --prompt hi --agent=general

"$ADAPTER" send --prompt hi --cwd /tmp/elsewhere
assert_args send --prompt hi --cwd /tmp/elsewhere

"$ADAPTER" send --prompt hi --cwd=/tmp/elsewhere --agent opencode
assert_args send --prompt hi --cwd=/tmp/elsewhere --agent opencode

"$ADAPTER" send --prompt hi --agent --model anthropic/test
assert_args send --prompt hi --agent --model anthropic/test

"$ADAPTER" send --prompt hi --cwd --model anthropic/test
assert_args send --prompt hi --cwd --model anthropic/test

"$ADAPTER" send --prompt hi --worktree feature-x
assert_args send --prompt hi --worktree feature-x

"$ADAPTER" session list --project /tmp/site
assert_args session list --project /tmp/site

unset DATAMACHINE_REAL_KIMAKI
shim_dir="$TMP/shim-bin"
real_dir="$TMP/real-bin"
mkdir -p "$shim_dir" "$real_dir"
cp "$ADAPTER" "$shim_dir/kimaki"
cp "$REAL_KIMAKI" "$real_dir/kimaki"
PATH="$shim_dir:$real_dir:$PATH" "$shim_dir/kimaki" send --prompt hi --agent opencode --cwd /tmp/site
assert_args send --prompt hi --agent opencode --cwd /tmp/site

echo "OK: datamachine-kimaki adapter delegates arguments unchanged"
