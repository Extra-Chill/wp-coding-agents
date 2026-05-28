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

primary="$TMP/repo"
worktree="$TMP/repo@native-cwd"
git init -q "$primary"
git -C "$primary" -c user.name='Test User' -c user.email='test@example.test' commit --allow-empty -qm 'initial'
git -C "$primary" worktree add -q -b native-cwd "$worktree"

"$ADAPTER" send --channel 123456789 --cwd "$worktree" --prompt 'Smoke native cwd handoff'
assert_args send --channel 123456789 --cwd "$worktree" --prompt 'Smoke native cwd handoff'

echo "OK: datamachine-kimaki passes native kimaki send --cwd routing through"
