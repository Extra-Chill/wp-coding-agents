#!/bin/bash
# tests/roadie-accounts.sh — subscription accounts move between OpenCode and
# subrouter without loss, using the real @subrouter/cli store.
#
# The subrouter version is the one the pinned Roadie release depends on, read
# from Roadie's package.json at that tag. ROADIE_TEST_PACKAGE_DIR may point at
# an installed Roadie package instead (offline runs). Tokens are fixtures.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

PIN="$(tr -d '[:space:]' < "$SCRIPT_DIR/bridges/roadie/roadie-version")"
if [ -n "${ROADIE_TEST_PACKAGE_DIR:-}" ]; then
  PKG="$ROADIE_TEST_PACKAGE_DIR"
else
  SUBROUTER_VERSION="$(curl -fsSL "https://raw.githubusercontent.com/Extra-Chill/roadie/v$PIN/cli/package.json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["dependencies"]["@subrouter/cli"])')" \
    || { echo "FAIL: could not read Roadie v$PIN's @subrouter/cli version"; exit 1; }
  PKG="$TMP/roadie-package"
  mkdir -p "$PKG"
  printf '{"name":"roadie-fixture","private":true}\n' > "$PKG/package.json"
  npm install --silent --no-audit --no-fund --prefix "$PKG" "@subrouter/cli@$SUBROUTER_VERSION" >/dev/null \
    || { echo "FAIL: npm install @subrouter/cli@$SUBROUTER_VERSION"; exit 1; }
  echo "using @subrouter/cli@$SUBROUTER_VERSION (Roadie v$PIN)"
fi

OC="$TMP/opencode"
export SUBROUTER_HOME="$TMP/subrouter"
mkdir -p "$OC"
FAR=4102444800000   # 2100-01-01
python3 - "$OC" "$FAR" <<'PY'
import json, sys, os
oc, far = sys.argv[1], int(sys.argv[2])
def acct(n, email=None, aid=None, expires=1000):
    a = {"type": "oauth", "refresh": f"refresh-{n}", "access": f"access-{n}", "expires": expires, "addedAt": 1, "lastUsed": 2}
    if email: a["email"] = email
    if aid: a["accountId"] = aid
    return a
pools = {
  "anthropic": {"version": 1, "activeIndex": 1, "accounts": [acct("a1", "one@example.com"), acct("a2", "two@example.com"), acct("a3", "three@example.com")]},
  "openai": {"version": 1, "activeIndex": 0, "accounts": [acct("o1", aid="org-1"), acct("o2", aid="org-2")]},
}
for name, pool in pools.items():
    json.dump(pool, open(f"{oc}/{name}-oauth-accounts.json", "w"))
auth = {
  # active anthropic account, refreshed later than the pool copy
  "anthropic": {"type": "oauth", "refresh": "refresh-a2-new", "access": "access-a2-new", "expires": far, "email": "two@example.com"},
  "openai": {"type": "oauth", "refresh": "refresh-o1", "access": "access-o1", "expires": 1000},
  "zai-coding-plan": {"type": "api", "key": "zai-key"},
  "opencode-go": {"type": "api", "key": "go-key"},
  "unknown-provider": {"type": "api", "key": "ignored"},
}
json.dump(auth, open(f"{oc}/auth.json", "w"))
PY

run() { node "$SCRIPT_DIR/bridges/roadie/accounts.mjs" "$@" --opencode-data "$OC" --roadie-package "$PKG"; }
store() { python3 -c "import json,sys; d=json.load(open('$SUBROUTER_HOME/auth.json'))['providers']; print(eval(sys.argv[1]))" "$1"; }

echo "==> import"
OUT="$(run import)"; check $? "import succeeds"
[ "$(store "len(d['anthropic']['accounts'])")" = 3 ]; check $? "anthropic pool: all 3 accounts"
[ "$(store "[a['email'] for a in d['anthropic']['accounts']]")" = "['one@example.com', 'two@example.com', 'three@example.com']" ]; check $? "anthropic order preserved"
[ "$(store "d['anthropic']['activeIndex']")" = 1 ]; check $? "anthropic active account preserved"
[ "$(store "d['anthropic']['accounts'][1]['refresh']")" = refresh-a2-new ]; check $? "fresher auth.json copy of the active account wins"
[ "$(store "len(d['openai']['accounts'])")" = 2 ]; check $? "openai pool: auth.json duplicate not added twice"
[ "$(store "d['zai']['accounts'][0]['key']")" = zai-key ]; check $? "zai-coding-plan maps to subrouter zai"
[ "$(store "d['opencode-go']['accounts'][0]['type']")" = api ]; check $? "opencode-go api key imported"
[ "$(store "'unknown-provider' in d")" = False ]; check $? "unsupported providers skipped"
[ "$(stat -c %a "$SUBROUTER_HOME/auth.json" 2>/dev/null || stat -f %Lp "$SUBROUTER_HOME/auth.json")" = 600 ]; check $? "subrouter store is 0600"
case "$OUT" in *refresh-*|*access-*|*-key*) check 1 "output contains no secrets" ;; *) check 0 "output contains no secrets" ;; esac

echo "==> re-import never overwrites what subrouter holds"
python3 - "$SUBROUTER_HOME/auth.json" <<'PY'
import json, sys
f = sys.argv[1]; d = json.load(open(f))
d['providers']['anthropic']['accounts'][1]['refresh'] = 'refresh-a2-rotated-by-subrouter'
json.dump(d, open(f, 'w'))
PY
run import >/dev/null; check $? "re-import succeeds"
[ "$(store "d['anthropic']['accounts'][1]['refresh']")" = refresh-a2-rotated-by-subrouter ]; check $? "subrouter's rotated token kept"

echo "==> export (rollback) writes subrouter's current tokens back"
run export >/dev/null; check $? "export succeeds"
python3 - "$OC" <<'PY'
import json, sys
oc = sys.argv[1]
pool = json.load(open(f"{oc}/anthropic-oauth-accounts.json"))
auth = json.load(open(f"{oc}/auth.json"))
assert [a["email"] for a in pool["accounts"]] == ["one@example.com", "two@example.com", "three@example.com"], pool
assert pool["activeIndex"] == 1 and pool["version"] == 1
assert pool["accounts"][1]["refresh"] == "refresh-a2-rotated-by-subrouter"
assert auth["anthropic"]["refresh"] == "refresh-a2-rotated-by-subrouter"
assert auth["zai-coding-plan"] == {"type": "api", "key": "zai-key"}
assert auth["unknown-provider"]["key"] == "ignored", "unrelated logins kept"
PY
check $? "pools and auth.json carry subrouter's tokens; unrelated logins kept"
[ -f "$OC/auth.json.before-roadie-rollback" ]; check $? "previous auth.json backed up"
[ "$(stat -c %a "$OC/auth.json" 2>/dev/null || stat -f %Lp "$OC/auth.json")" = 600 ]; check $? "exported auth.json is 0600"

echo "==> installer path (stdin, as the current user)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"
rm -rf "$SUBROUTER_HOME"
roadie_package_dir() { printf '%s\n' "$PKG"; }
_roadie_opencode_data_dir() { printf '%s\n' "$OC"; }
LOCAL_MODE=true _roadie_accounts import >/dev/null; check $? "_roadie_accounts import runs the script over stdin"
[ "$(store "len(d['anthropic']['accounts'])")" = 3 ]; check $? "installer path stored the pool"

echo "==> a missing Roadie package fails loudly"
node "$SCRIPT_DIR/bridges/roadie/accounts.mjs" import --opencode-data "$OC" --roadie-package "$TMP/nope" 2>/dev/null
[ $? -ne 0 ]; check $? "non-zero exit without @subrouter/cli"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-accounts.sh ($PASS assertions)"
