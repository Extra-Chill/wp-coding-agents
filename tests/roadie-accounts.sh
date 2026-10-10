#!/bin/bash
# tests/roadie-accounts.sh — the bridge moves subscription accounts and model
# rotations through Roadie's own credential commands (#709).
#
# Account import/export semantics (order, active account, dedupe, 0600 files)
# belong to `roadie credentials import-opencode|export-opencode` and are tested
# in Roadie. This test pins the bridge's side of that contract with a stub
# `roadie` that records its argv and environment and keeps a real
# rotation.json, so it needs neither real accounts nor any subrouter package.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

STUB="$TMP/bin/roadie"
CALLS="$TMP/calls"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'SH'
#!/bin/bash
# Records argv plus the env the bridge must set or strip; implements just
# enough of `credentials rotation set` to keep a real rotation.json.
{
  printf 'argv:'; printf ' %s' "$@"; printf '\n'
  printf 'env: ROADIE_DATA_DIR=%s OPENCODE_PROCESS=%s AGENT_TOKEN=%s\n' \
    "${ROADIE_DATA_DIR:-}" "${ROADIE_OPENCODE_PROCESS:-unset}" "${ROADIE_AGENT_TOKEN:-unset}"
} >> "$ROADIE_STUB_CALLS"
if [ "${ROADIE_STUB_FAIL:-}" = "$2" ]; then echo "stub failure for $2" >&2; exit 3; fi
if [ "$1 $2 $3" = "credentials rotation set" ]; then
  name="$4"; shift 4
  models=()
  while [ $# -gt 0 ]; do
    case "$1" in --pool) shift 2 ;; *) models+=("$1"); shift ;; esac
  done
  mkdir -p "$ROADIE_DATA_DIR/credentials/shared"
  python3 - "$ROADIE_DATA_DIR/credentials/shared/rotation.json" "$name" "${models[@]}" <<'PY'
import json, os, sys
path, name, models = sys.argv[1], sys.argv[2], sys.argv[3:]
data = json.load(open(path)) if os.path.exists(path) else {}
data[name] = models
json.dump(data, open(path, "w"))
PY
fi
echo "${2} ok"
SH
chmod +x "$STUB"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

export ROADIE_STUB_CALLS="$CALLS"
ROADIE_BIN="$STUB"
ROADIE_DATA_DIR="$TMP/roadie-data"
LOCAL_MODE=true
OC="$TMP/opencode"
_roadie_opencode_data_dir() { printf '%s\n' "$OC"; }

echo "==> account import/export use roadie credentials"
: > "$CALLS"
# The agent-mode markers of a Roadie tool shell must not leak into the call:
# Roadie refuses operator-only credential commands in agent mode.
ROADIE_OPENCODE_PROCESS=1 ROADIE_AGENT_TOKEN=tok _roadie_accounts import >/dev/null
check $? "_roadie_accounts import succeeds"
grep -qx "argv: credentials import-opencode --opencode-data $OC --pool shared" "$CALLS"; check $? "import runs credentials import-opencode on the shared pool"
grep -qx "env: ROADIE_DATA_DIR=$ROADIE_DATA_DIR OPENCODE_PROCESS=unset AGENT_TOKEN=unset" "$CALLS"; check $? "runs against the bridge data dir with agent-mode markers stripped"
: > "$CALLS"
_roadie_accounts export >/dev/null; check $? "_roadie_accounts export succeeds"
grep -qx "argv: credentials export-opencode --opencode-data $OC --pool shared" "$CALLS"; check $? "export runs credentials export-opencode"
ROADIE_STUB_FAIL=import-opencode _roadie_accounts import >/dev/null 2>&1
[ $? -ne 0 ]; check $? "a failing import is reported as failure"

echo "==> rollback command"
ROLLBACK="$(roadie_accounts_rollback_command)"
[ "$ROLLBACK" = "ROADIE_DATA_DIR=$ROADIE_DATA_DIR $STUB credentials export-opencode --opencode-data $OC --pool shared" ]
check $? "rollback names export-opencode with the data dir and binary"
case "$ROLLBACK" in *accounts.mjs*|*subrouter*) check 1 "rollback has no subrouter path" ;; *) check 0 "rollback has no subrouter path" ;; esac

echo "==> rotations: one per stored direct model, existing ones kept"
: > "$CALLS"
OUT="$(_roadie_ensure_rotations '{"anthropic-claude-x":["anthropic/claude-x"],"openai-gpt-y":["openai/gpt-y"]}')"
check $? "_roadie_ensure_rotations succeeds"
ROT="$ROADIE_DATA_DIR/credentials/shared/rotation.json"
[ "$(python3 -c "import json; print(json.load(open('$ROT')))")" = "{'anthropic-claude-x': ['anthropic/claude-x'], 'openai-gpt-y': ['openai/gpt-y']}" ]
check $? "rotations created with exactly their model"
grep -qx "argv: credentials rotation set anthropic-claude-x anthropic/claude-x --pool shared" "$CALLS"; check $? "uses roadie credentials rotation set"
printf '%s\n' "$OUT" | grep -qx "rotation openai-gpt-y: openai/gpt-y"; check $? "reports each created rotation"
python3 - "$ROT" <<'PY'
import json, sys
f = sys.argv[1]; d = json.load(open(f))
d["anthropic-claude-x"] = ["anthropic/claude-x", "openai/gpt-y"]   # operator fallback
json.dump(d, open(f, "w"))
PY
: > "$CALLS"
OUT="$(_roadie_ensure_rotations '{"anthropic-claude-x":["anthropic/claude-x"]}')"
printf '%s\n' "$OUT" | grep -qx "rotation anthropic-claude-x: kept existing"; check $? "existing rotation reported as kept"
[ ! -s "$CALLS" ]; check $? "existing rotation not rewritten"
[ "$(python3 -c "import json; print(json.load(open('$ROT'))['anthropic-claude-x'])")" = "['anthropic/claude-x', 'openai/gpt-y']" ]
check $? "operator-edited rotation survives"
_roadie_ensure_rotations '{}' >/dev/null; check $? "no rotations needed is a no-op"
ROADIE_STUB_FAIL=rotation _roadie_ensure_rotations '{"xai-grok":["xai/grok"]}' >/dev/null 2>&1
[ $? -ne 0 ]; check $? "a failing rotation set is reported as failure"

echo "==> no subrouter dependency"
! grep -rn "@subrouter" "$SCRIPT_DIR/bridges" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/upgrade.sh" "$SCRIPT_DIR/setup.sh" >/dev/null
check $? "bridge, lib and installers never load @subrouter/*"
[ ! -e "$SCRIPT_DIR/bridges/roadie/accounts.mjs" ]; check $? "accounts.mjs is retired"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-accounts.sh ($PASS assertions)"
