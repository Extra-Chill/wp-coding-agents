#!/bin/bash
# tests/roadie-pi-backend.sh — the managed Roadie unit runs Pi only when Pi
# is installed from the pin and passes Roadie's version gate (#730).
#
# Roadie's built-in default backend is Pi (roadie v0.59.0). A unit that
# selects Pi without a working `pi` exits 64 and crash-loops, so every path
# that cannot prove a working Pi renders ROADIE_BACKEND=opencode instead.
# Backend keys are installer-owned: an upgrade replaces the installed unit's
# values rather than preserving them, so hosts move to Pi once Pi verifies.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/grants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"

log() { :; }
warn() { printf 'WARN: %s\n' "$*" >> "$TMP/warn.log"; }
systemctl() { :; }

PI_PIN="$(tr -d '[:space:]' < "$SCRIPT_DIR/bridges/roadie/pi-version")"

# Fake npm: records argv; `install --prefix P <pkg>@<v>` lays out Pi at P with
# a `pi` that prints $FAKE_PI_VERSION. FAKE_NPM_FAIL=1 makes installs fail.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
[ "${FAKE_NPM_FAIL:-0}" != 1 ] || exit 1
prefix=""
spec=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift ;;
    @earendil-works/*) spec="$1" ;;
  esac
  shift
done
[ -n "$prefix" ] && [ -n "$spec" ] || exit 0
pkg="$prefix/lib/node_modules/@earendil-works/pi-coding-agent"
mkdir -p "$pkg" "$prefix/bin"
printf '{"version":"%s"}\n' "${spec##*@}" > "$pkg/package.json"
printf '#!/bin/sh\necho "%s"\n' "$FAKE_PI_VERSION" > "$prefix/bin/pi"
chmod 0700 "$prefix/bin/pi"
SH
chmod +x "$TMP/bin/npm"
export NPM_LOG="$TMP/npm.log" FAKE_PI_VERSION="$PI_PIN"

SYSTEMD_UNIT_DIR="$TMP/systemd"
mkdir -p "$SYSTEMD_UNIT_DIR" "$TMP/site"
printf '{\n  "model": "roadie/opus"\n}\n' > "$TMP/site/opencode.json"

unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT AGENT_SLUG
initialize_roadie_overrides
ROADIE_UNIT=roadie.service
SITE_PATH="$TMP/site"
SERVICE_USER="$(id -un)"
SERVICE_HOME="$TMP/home"
SERVICE_USER_FORCED=true
LOCAL_MODE=false
ROADIE_DATA_DIR="$TMP/home/.roadie"
ROADIE_DATA_DIR_EXPLICIT=false
ROADIE_LOCK_PORT=""
ROADIE_LOCK_PORT_EXPLICIT=false
AGENT_SLUG=""
AGENT_SLUG_EXPLICIT=false
ROADIE_SYSTEM_PREFIX="$TMP/roadie-prefix"
ROADIE_PI_SYSTEM_PREFIX="$TMP/pi-prefix"
ROADIE_SECRETS_ROOT="$TMP/secrets"
PATH="$TMP/bin:$PATH"
DRY_RUN=false
TIMESTAMP="test"
UPDATED_ITEMS=()
PENDING_ITEMS=()
WP_CMD=wp
WP_CLI_TRANSPORT=(wp)
IS_STUDIO=false
WP_CODING_AGENTS_TEST_EUID=0
ROADIE_BIN="$(roadie_bin)"
PI_BIN="$TMP/pi-prefix/bin/pi"

reset_selection() {
  unset ROADIE_PI_VERIFIED
  : > "$NPM_LOG"
  : > "$TMP/warn.log"
}

echo "==> a verified Pi install selects the Pi backend"
reset_selection
_roadie_select_backend
grep -qxF "install -g --prefix $TMP/pi-prefix @earendil-works/pi-coding-agent@$PI_PIN" "$NPM_LOG"; check $? "npm installs the pinned Pi into its system prefix"
[ "$(_roadie_pi_installed_version)" = "$PI_PIN" ]; check $? "installed Pi version is read from package.json ($PI_PIN)"
[ "$(stat -c %a "$PI_BIN" 2>/dev/null || stat -f %Lp "$PI_BIN")" = 755 ]; check $? "Pi prefix is made world-readable for the service user"
[ "$ROADIE_AGENT_BACKEND" = pi ]; check $? "backend is pi"
[ "$ROADIE_PI_BIN" = "$PI_BIN" ]; check $? "ROADIE_PI_BIN is the managed binary"
[ "$ROADIE_PI_MODEL" = roadie/opus ]; check $? "ROADIE_PI_MODEL follows the site's opencode.json model"

echo "==> the pinned version installed is a no-op"
reset_selection
_roadie_select_backend
[ ! -s "$NPM_LOG" ]; check $? "no npm call when the pinned Pi is installed"
[ "$ROADIE_AGENT_BACKEND" = pi ]; check $? "backend stays pi"

echo "==> verification runs once per run; the model follows each site"
: > "$NPM_LOG"
mkdir -p "$TMP/site-b"
printf '{"model":"roadie/sol"}\n' > "$TMP/site-b/opencode.json"
SITE_PATH="$TMP/site-b" _roadie_select_backend
[ "$ROADIE_PI_MODEL" = roadie/sol ]; check $? "a second instance renders its own site's model"
[ ! -s "$NPM_LOG" ]; check $? "a second instance reuses the verified install"

echo "==> a Pi below Roadie's major gate keeps OpenCode"
reset_selection
printf '#!/bin/sh\necho "0.73.1"\n' > "$PI_BIN"
_roadie_select_backend
[ "$ROADIE_AGENT_BACKEND" = opencode ]; check $? "backend is opencode for Pi 0.x"
[ -z "$ROADIE_PI_BIN" ] && [ -z "$ROADIE_PI_MODEL" ]; check $? "no Pi keys rendered"
grep -q "below 1.x" "$TMP/warn.log"; check $? "the failed gate is reported"

echo "==> a pi that cannot run keeps OpenCode"
reset_selection
printf '#!/bin/sh\nexit 127\n' > "$PI_BIN"
_roadie_select_backend
[ "$ROADIE_AGENT_BACKEND" = opencode ]; check $? "backend is opencode when pi --version fails"

echo "==> a failed install keeps OpenCode"
reset_selection
rm -rf "$TMP/pi-prefix"
FAKE_NPM_FAIL=1 _roadie_select_backend
[ "$ROADIE_AGENT_BACKEND" = opencode ]; check $? "backend is opencode when npm install fails"
grep -q "Pi is not installed" "$TMP/warn.log"; check $? "the failed install is reported"

echo "==> a non-root upgrade reports a root repair and keeps OpenCode"
reset_selection
PENDING_ITEMS=()
WP_CODING_AGENTS_TEST_EUID=1000 _roadie_select_backend
[ ! -s "$NPM_LOG" ]; check $? "no npm call without root"
[ "$ROADIE_AGENT_BACKEND" = opencode ]; check $? "backend is opencode"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -qxF "Pi $PI_PIN install (root)"; check $? "root repair is listed as pending"

echo "==> upgrade flips an installed OpenCode unit to Pi, exactly once"
reset_selection
cat > "$SYSTEMD_UNIT_DIR/roadie.service" <<EOF
[Service]
User=$SERVICE_USER
WorkingDirectory=$TMP/site
Environment=HOME=$TMP/home
Environment=PATH=/usr/bin:/bin
Environment=ROADIE_DATA_DIR=$TMP/home/.roadie
Environment=ROADIE_BACKEND=opencode
Environment=DATAMACHINE_SITE_PATH=$TMP/site
Environment=HOST_CUSTOM=preserved
ExecStart=/usr/bin/roadie --data-dir $TMP/home/.roadie --auto-restart
EOF
UNIT="$SYSTEMD_UNIT_DIR/roadie.service"
bridge_update_systemd >/dev/null 2>&1
unit_has_once() { [ "$(grep -cFx "Environment=$1" "$UNIT")" -eq 1 ]; }
unit_has_once ROADIE_BACKEND=pi; check $? "ROADIE_BACKEND=pi replaces the installed opencode value"
! grep -qFx "Environment=ROADIE_BACKEND=opencode" "$UNIT"; check $? "the stale opencode backend is gone"
unit_has_once "ROADIE_PI_BIN=$PI_BIN"; check $? "ROADIE_PI_BIN rendered once"
unit_has_once ROADIE_PI_MODEL=roadie/opus; check $? "ROADIE_PI_MODEL rendered once"
unit_has_once HOST_CUSTOM=preserved; check $? "operator env survives"
# Installer-owned keys are re-appended in template order, so the first upgrade
# may reorder them; from then on the unit is stable.
reset_selection
bridge_update_systemd >/dev/null 2>&1
cp "$UNIT" "$TMP/converged.unit"
reset_selection
bridge_update_systemd >/dev/null 2>&1
cmp -s "$UNIT" "$TMP/converged.unit"; check $? "re-runs converge to a byte-identical unit"
unit_has_once ROADIE_BACKEND=pi; check $? "ROADIE_BACKEND=pi still once after re-runs"

echo "==> a later failed Pi verification moves the unit back to OpenCode"
reset_selection
printf '#!/bin/sh\nexit 1\n' > "$PI_BIN"
bridge_update_systemd >/dev/null 2>&1
unit_has_once ROADIE_BACKEND=opencode; check $? "ROADIE_BACKEND=opencode"
! grep -q '^Environment=ROADIE_PI_' "$UNIT"; check $? "Pi keys are removed"

echo "==> launchd plist and manual command carry the selected backend"
ROADIE_AGENT_BACKEND=pi ROADIE_PI_BIN="$PI_BIN" ROADIE_PI_MODEL=roadie/opus
PLIST="$(LOCAL_MODE=true ROADIE_BIN=/usr/bin/roadie bridge_render_launchd com.wp.roadie 2>/dev/null)"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_BACKEND</key>' | grep -q '<string>pi</string>'; check $? "launchd ROADIE_BACKEND=pi"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_PI_BIN</key>' | grep -qF "<string>$PI_BIN</string>"; check $? "launchd ROADIE_PI_BIN"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_PI_MODEL</key>' | grep -q '<string>roadie/opus</string>'; check $? "launchd ROADIE_PI_MODEL"
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$PLIST" > "$TMP/roadie.plist"
  plutil -lint "$TMP/roadie.plist" >/dev/null; check $? "launchd plist stays valid"
fi
_roadie_manual_command | grep -q "ROADIE_BACKEND=pi ROADIE_PI_BIN='$PI_BIN' ROADIE_PI_MODEL='roadie/opus'"; check $? "manual command carries the Pi keys"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: tests/roadie-pi-backend.sh ($FAIL failed, $PASS passed)"
  exit 1
fi
echo "PASS: tests/roadie-pi-backend.sh ($PASS assertions)"
