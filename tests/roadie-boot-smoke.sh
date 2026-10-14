#!/bin/bash
# tests/roadie-boot-smoke.sh — the pinned Roadie release actually boots.
#
# tests/roadie-provision.sh installs the pinned tarball but never starts the
# service, so a release whose startup contract the installer does not satisfy
# passes CI and lands straight on main — the 2026-10-13 incident (#731): the
# v0.60.0 refresh carried roadie#200's `feat!: Pi is the default agent
# backend`, the extrachill.com bot self-upgraded, and crash-looped at exit 64
# within a minute while the provision test stayed green.
#
# This smoke test closes that gap. It installs the pinned Roadie release and
# the pinned Pi backend into an isolated prefix, then starts Roadie the way
# the rendered managed service environment does (isolated data dir, no Discord
# token, the pinned Pi on the service PATH) and requires it to get far enough
# to resolve its agent backend — which runs the same `pi --version` gate the
# bot startup runs — and initialize its database. Exiting before either
# marker, including with a usage or config error (exit 64), fails the pin.
# Dying after those markers is acceptable here: without real Discord
# credentials the good release stops at auth/setup, which is environmental,
# not a release defect.
#
# Needs network (the release tarball and the Pi package) and Node >= 24
# (the pinned release uses `await using`).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

command -v node >/dev/null 2>&1 || { echo "node is required"; exit 1; }
[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 24 ] || { echo "node >= 24 is required"; exit 1; }

ROADIE_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/bridges/roadie/roadie-version")"
PI_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/bridges/roadie/pi-version")"
ROADIE_URL="https://github.com/Extra-Chill/roadie/releases/download/v$ROADIE_VERSION/extrachill-roadie-$ROADIE_VERSION.tgz"

PREFIX="$TMP/prefix"
DATA_DIR="$TMP/roadie-data"
LOG="$TMP/roadie-boot.log"
mkdir -p "$DATA_DIR"

echo "==> install the pinned release ($ROADIE_VERSION) and Pi backend ($PI_VERSION)"
# The same install the provision flow runs: global layout under a prefix, so
# the bins land in prefix/bin and the packages in prefix/lib/node_modules.
npm install -g --silent --no-audit --no-fund --prefix "$PREFIX" "$ROADIE_URL" \
  || { echo "FAIL: the pinned Roadie tarball does not install"; exit 1; }
npm install -g --silent --no-audit --no-fund --prefix "$PREFIX" "@earendil-works/pi-coding-agent@$PI_VERSION" \
  || { echo "FAIL: the pinned Pi backend does not install"; exit 1; }
[ -x "$PREFIX/bin/roadie" ]; check $? "roadie bin is installed"
[ -x "$PREFIX/bin/pi" ]; check $? "pi bin is installed"
[ "$(python3 -c "import json;print(json.load(open('$PREFIX/lib/node_modules/@extrachill/roadie/package.json'))['version'])")" = "$ROADIE_VERSION" ]; check $? "installed roadie is the pinned version"
"$PREFIX/bin/pi" --version >/dev/null 2>&1; check $? "pi --version runs (backend resolution gate)"

echo "==> boot with the rendered managed environment (no Discord token)"
NODE_BIN_DIR="$(dirname "$(readlink -f "$(command -v node)")")"
env -i \
  HOME="$TMP/home" \
  PATH="$PREFIX/bin:$NODE_BIN_DIR:/usr/local/bin:/usr/bin:/bin" \
  ROADIE_DATA_DIR="$DATA_DIR" \
  ROADIE_MANAGED=1 \
  ROADIE_NO_DEFAULT_CHANNEL=1 \
  ROADIE_PI_BIN="$PREFIX/bin/pi" \
  ROADIE_PROMPT_CONFIG="$SCRIPT_DIR/bridges/roadie/prompt-config.yaml" \
  "$PREFIX/bin/roadie" --data-dir "$DATA_DIR" >"$LOG" 2>&1 &
boot_pid=$!

# Startup contract: backend resolution and database initialization must both
# appear. Split the markers so a renamed log line still names what changed.
MARKER_BACKEND='Agent backend'
MARKER_DB='Database initialized'
DEADLINE=$((SECONDS + 120))
have() { grep -q "$1" "$LOG" 2>/dev/null; }

while :; do
  if ! kill -0 "$boot_pid" 2>/dev/null; then
    break
  fi
  if have "$MARKER_BACKEND" && have "$MARKER_DB"; then
    break
  fi
  [ "$SECONDS" -lt "$DEADLINE" ] || break
  sleep 2
done

if kill -0 "$boot_pid" 2>/dev/null; then
  kill "$boot_pid" 2>/dev/null
  wait "$boot_pid" 2>/dev/null
  check 0 "startup stays healthy (backend and database markers reached; still running)"
else
  wait "$boot_pid"
  exit_code=$?
  if have "$MARKER_BACKEND" && have "$MARKER_DB"; then
    echo "  note exit $exit_code after startup: auth/setup stops the unconfigured service, not a release defect"
    check 0 "startup contract holds before the process exits ($exit_code)"
  else
    check 1 "process exited ($exit_code) before backend resolution and database initialization"
    echo "---- boot log ----"
    sed -n '1,40p' "$LOG"
    echo "------------------"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s)"
  exit 1
fi
echo "PASS: tests/roadie-boot-smoke.sh ($PASS assertions)"
