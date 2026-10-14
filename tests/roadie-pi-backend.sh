#!/bin/bash
# tests/roadie-pi-backend.sh — Pi is Roadie's only agent backend (roadie#177,
# v0.67.0). The bridge installs the pinned Pi, renders ROADIE_PI_BIN once Pi
# passes Roadie's version gate as the service user, never renders
# ROADIE_BACKEND (Roadie rejects any value but `pi`), and takes
# ROADIE_PI_MODEL from the operator or the installed unit, never from
# opencode.json (a fixture below carries one to prove it is ignored).
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

unset ROADIE_UNIT ROADIE_DATA_DIR ROADIE_LOCK_PORT ROADIE_PI_MODEL ROADIE_PI_TITLE_MODEL ROADIE_PI_BIN ROADIE_POOL_URL AGENT_SLUG
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

echo "==> a verified Pi install renders the managed binary"
reset_selection
_roadie_select_pi
grep -qxF "install -g --prefix $TMP/pi-prefix @earendil-works/pi-coding-agent@$PI_PIN" "$NPM_LOG"; check $? "npm installs the pinned Pi into its system prefix"
[ "$(_roadie_pi_installed_version)" = "$PI_PIN" ]; check $? "installed Pi version is read from package.json ($PI_PIN)"
[ "$(stat -c %a "$PI_BIN" 2>/dev/null || stat -f %Lp "$PI_BIN")" = 755 ]; check $? "Pi prefix is made world-readable for the service user"
[ "$ROADIE_PI_BIN" = "$PI_BIN" ]; check $? "ROADIE_PI_BIN is the managed binary"
[ -z "$ROADIE_PI_MODEL" ]; check $? "ROADIE_PI_MODEL is not derived from opencode.json"

echo "==> the pinned version installed is a no-op"
reset_selection
_roadie_select_pi
[ ! -s "$NPM_LOG" ]; check $? "no npm call when the pinned Pi is installed"
[ "$ROADIE_PI_BIN" = "$PI_BIN" ]; check $? "ROADIE_PI_BIN stays the managed binary"
cp "$PI_BIN" "$TMP/pi.orig"

echo "==> a Pi below Roadie's major gate is reported"
reset_selection
PENDING_ITEMS=()
printf '#!/bin/sh\necho "0.73.1"\n' > "$PI_BIN"
_roadie_select_pi
[ -z "$ROADIE_PI_BIN" ]; check $? "ROADIE_PI_BIN is left out"
grep -q "below 1.x" "$TMP/warn.log"; check $? "the failed gate is reported"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -q "^Pi 1.x for Roadie"; check $? "the failed gate is a pending item"

echo "==> a pi that cannot run is reported"
reset_selection
printf '#!/bin/sh\nexit 127\n' > "$PI_BIN"
_roadie_select_pi
[ -z "$ROADIE_PI_BIN" ]; check $? "ROADIE_PI_BIN is left out when pi --version fails"

echo "==> a failed install is reported"
reset_selection
rm -rf "$TMP/pi-prefix"
FAKE_NPM_FAIL=1 _roadie_select_pi
[ -z "$ROADIE_PI_BIN" ]; check $? "ROADIE_PI_BIN is left out when npm install fails"
grep -q "Pi is not installed" "$TMP/warn.log"; check $? "the failed install is reported"

echo "==> a non-root upgrade reports a root repair"
reset_selection
PENDING_ITEMS=()
WP_CODING_AGENTS_TEST_EUID=1000 _roadie_select_pi
[ ! -s "$NPM_LOG" ]; check $? "no npm call without root"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -qxF "Pi $PI_PIN install (root)"; check $? "root repair is listed as pending"

echo "==> upgrade drops the retired OpenCode backend from an installed unit"
reset_selection
_roadie_select_pi
[ "$ROADIE_PI_BIN" = "$PI_BIN" ]; check $? "Pi reinstalled for the upgrade cases"
UNIT="$SYSTEMD_UNIT_DIR/roadie.service"
cat > "$UNIT" <<UNIT_EOF
[Service]
User=$SERVICE_USER
WorkingDirectory=$TMP/site
Environment=HOME=$TMP/home
Environment=PATH=/usr/bin:/bin
Environment=ROADIE_DATA_DIR=$TMP/home/.roadie
Environment=ROADIE_BACKEND=opencode
Environment=ROADIE_PI_MODEL=roadie/opus
Environment=ROADIE_PI_TITLE_MODEL=zai/glm-flash
Environment=DATAMACHINE_SITE_PATH=$TMP/site
Environment=HOST_CUSTOM=preserved
ExecStart=/usr/bin/roadie --data-dir $TMP/home/.roadie --auto-restart
UNIT_EOF
upgrade() { reset_selection; _roadie_resolve_instance; bridge_update_systemd >/dev/null 2>&1; }
unit_has_once() { [ "$(grep -cFx "Environment=$1" "$UNIT")" -eq 1 ]; }
upgrade
! grep -q "^Environment=ROADIE_BACKEND=" "$UNIT"; check $? "ROADIE_BACKEND is no longer rendered"
unit_has_once "ROADIE_PI_BIN=$PI_BIN"; check $? "ROADIE_PI_BIN rendered once"
unit_has_once ROADIE_PI_MODEL=roadie/opus; check $? "the installed unit keeps its ROADIE_PI_MODEL"
unit_has_once ROADIE_PI_TITLE_MODEL=zai/glm-flash; check $? "the installed unit keeps its ROADIE_PI_TITLE_MODEL"
unit_has_once HOST_CUSTOM=preserved; check $? "operator env survives"
# Installer-owned keys are re-appended in template order, so the first upgrade
# may reorder them; from then on the unit is stable.
upgrade
cp "$UNIT" "$TMP/converged.unit"
upgrade
cmp -s "$UNIT" "$TMP/converged.unit"; check $? "re-runs converge to a byte-identical unit"

echo "==> an operator ROADIE_PI_MODEL replaces the installed one"
ROADIE_PI_MODEL=roadie/sol
ROADIE_PI_MODEL_EXPLICIT=true
upgrade
unit_has_once ROADIE_PI_MODEL=roadie/sol; check $? "operator model rendered once"
! grep -qFx "Environment=ROADIE_PI_MODEL=roadie/opus" "$UNIT"; check $? "the previous model is replaced"
ROADIE_PI_MODEL_EXPLICIT=false
upgrade
unit_has_once ROADIE_PI_MODEL=roadie/sol; check $? "the operator model then persists from the unit"

echo "==> an operator ROADIE_PI_TITLE_MODEL replaces the installed one"
ROADIE_PI_TITLE_MODEL=opencode-go/haiku
ROADIE_PI_TITLE_MODEL_EXPLICIT=true
upgrade
unit_has_once ROADIE_PI_TITLE_MODEL=opencode-go/haiku; check $? "operator title model rendered once"
! grep -qFx "Environment=ROADIE_PI_TITLE_MODEL=zai/glm-flash" "$UNIT"; check $? "the previous title model is replaced"
ROADIE_PI_TITLE_MODEL_EXPLICIT=false
upgrade
unit_has_once ROADIE_PI_TITLE_MODEL=opencode-go/haiku; check $? "the operator title model then persists from the unit"

echo "==> a unit without a model leaves Pi's settings.json default"
grep -v '^Environment=ROADIE_PI_\(TITLE_\)\{0,1\}MODEL=' "$UNIT" > "$UNIT.new" && mv "$UNIT.new" "$UNIT"
upgrade
! grep -q "^Environment=ROADIE_PI_MODEL=" "$UNIT"; check $? "no ROADIE_PI_MODEL is invented"
! grep -q "^Environment=ROADIE_PI_TITLE_MODEL=" "$UNIT"; check $? "no ROADIE_PI_TITLE_MODEL is invented"

echo "==> a later failed Pi verification drops only ROADIE_PI_BIN"
printf '#!/bin/sh\nexit 1\n' > "$PI_BIN"
upgrade
! grep -q '^Environment=ROADIE_PI_BIN=' "$UNIT"; check $? "ROADIE_PI_BIN is removed"
! grep -q "^Environment=ROADIE_BACKEND=" "$UNIT"; check $? "no OpenCode fallback is rendered"
cp "$TMP/pi.orig" "$PI_BIN"

echo "==> launchd plist and manual command carry the Pi keys"
ROADIE_PI_BIN="$PI_BIN"
ROADIE_PI_MODEL=roadie/opus
ROADIE_PI_TITLE_MODEL=zai/glm-flash
PLIST="$(LOCAL_MODE=true ROADIE_BIN=/usr/bin/roadie bridge_render_launchd com.wp.roadie 2>/dev/null)"
! printf '%s' "$PLIST" | grep -q '<key>ROADIE_BACKEND</key>'; check $? "launchd sets no ROADIE_BACKEND"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_PI_BIN</key>' | grep -qF "<string>$PI_BIN</string>"; check $? "launchd ROADIE_PI_BIN"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_PI_MODEL</key>' | grep -q '<string>roadie/opus</string>'; check $? "launchd ROADIE_PI_MODEL"
printf '%s' "$PLIST" | grep -A1 '<key>ROADIE_PI_TITLE_MODEL</key>' | grep -q '<string>zai/glm-flash</string>'; check $? "launchd ROADIE_PI_TITLE_MODEL"
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$PLIST" > "$TMP/roadie.plist"
  plutil -lint "$TMP/roadie.plist" >/dev/null; check $? "launchd plist stays valid"
fi
_roadie_manual_command | grep -q "^ROADIE_MANAGED=1 ROADIE_PI_BIN='$PI_BIN' ROADIE_PI_MODEL='roadie/opus' ROADIE_PI_TITLE_MODEL='zai/glm-flash'"; check $? "manual command carries the Pi keys"
! _roadie_manual_command | grep -q "ROADIE_BACKEND"; check $? "manual command sets no ROADIE_BACKEND"

echo "==> no removed Roadie flag is rendered"
REMOVED='ROADIE_BACKEND|ROADIE_PI_CHANNELS|opencode-hostname|opencode-port|no-subrouter|--backend'
! grep -qE "$REMOVED" "$UNIT"; check $? "systemd unit"
! printf '%s' "$PLIST" | grep -qE "$REMOVED"; check $? "launchd plist"
! _roadie_manual_command | grep -qE "$REMOVED"; check $? "manual command"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: tests/roadie-pi-backend.sh ($FAIL failed, $PASS passed)"
  exit 1
fi
echo "PASS: tests/roadie-pi-backend.sh ($PASS assertions)"
