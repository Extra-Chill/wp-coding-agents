#!/bin/bash
# tests/service-identity-adoption.sh — Regression coverage for issue #204.
#
# upgrade.sh hardcodes RUN_AS_ROOT=true. On a non-root install
# (kimaki.service has User=opencode) Phase 5 re-rendered the unit with
# User=root — a silent service-identity flip that creates root-owned state
# files, breaks the next non-root start, and re-introduces the
# root-homed-path dispatch trap (#198/#93). It also dropped the existing
# unit's UMask= directive on every refresh.
#
# Asserts:
#   1. adopt_service_identity_from_units reads User= from the existing unit
#      and re-derives SERVICE_USER / SERVICE_HOME / KIMAKI_DATA_DIR /
#      RUN_AS_ROOT to match (root-default script + opencode unit → opencode).
#   2. Adoption is a no-op when the unit already matches the script default.
#   3. Adoption is skipped when SERVICE_USER_FORCED=true (--root/--non-root).
#   4. Adoption is skipped in LOCAL_MODE (no systemd).
#   5. _preserve_systemd_umask carries an existing UMask= line into the
#      re-rendered env block, and is a no-op when the unit has none.
#   6. End-to-end: a re-render after adoption keeps User=opencode and
#      UMask=0002 — the exact production diff from #204 must NOT appear.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
fail_list=""

assert() {
  local label="$1" ok="$2"
  if [ "$ok" = "0" ]; then
    echo "  ok   $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label"
    FAIL=$((FAIL + 1))
    fail_list="$fail_list
  - $label"
  fi
}

# Minimal env so bridges/_dispatch.sh sources cleanly.
export DRY_RUN=false
export PLATFORM="linux"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/_dispatch.sh"

# Mock unit dir with a non-root kimaki unit (the #204 production shape).
UNIT_DIR="$TMP/systemd"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/kimaki.service" <<'EOF'
[Unit]
Description=Kimaki Discord Bot (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=opencode
WorkingDirectory=/var/www/site
UMask=0002
Environment=HOME=/home/opencode
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/kimaki
Restart=always

[Install]
WantedBy=multi-user.target
EOF

export SYSTEMD_UNIT_DIR="$UNIT_DIR"

# Stand-in for the loaded bridge's unit list.
bridge_systemd_units() { echo "kimaki.service"; }

# ---------------------------------------------------------------------------
echo "==> adoption: root default + opencode unit -> opencode"
LOCAL_MODE=false
SERVICE_USER_FORCED=false
SERVICE_USER="root"
SERVICE_HOME="/root"
KIMAKI_DATA_DIR="/root/.kimaki"
RUN_AS_ROOT=true

adopt_service_identity_from_units

assert "SERVICE_USER adopted from unit"        "$([ "$SERVICE_USER" = "opencode" ]; echo $?)"
assert "RUN_AS_ROOT flipped to false"          "$([ "$RUN_AS_ROOT" = "false" ]; echo $?)"
assert "SERVICE_HOME re-derived"               "$([ "$SERVICE_HOME" != "/root" ]; echo $?)"
assert "KIMAKI_DATA_DIR re-derived"            "$([ "$KIMAKI_DATA_DIR" != "/root/.kimaki" ]; echo $?)"

# ---------------------------------------------------------------------------
echo "==> adoption: no-op when unit matches script default"
SERVICE_USER="opencode"
SERVICE_HOME="/home/opencode"
KIMAKI_DATA_DIR="/home/opencode/.kimaki"
RUN_AS_ROOT=false

adopt_service_identity_from_units

assert "matching user unchanged"               "$([ "$SERVICE_USER" = "opencode" ]; echo $?)"
assert "matching home unchanged"               "$([ "$SERVICE_HOME" = "/home/opencode" ]; echo $?)"

# ---------------------------------------------------------------------------
echo "==> adoption: skipped when SERVICE_USER_FORCED=true"
SERVICE_USER_FORCED=true
SERVICE_USER="root"
SERVICE_HOME="/root"
KIMAKI_DATA_DIR="/root/.kimaki"
RUN_AS_ROOT=true

adopt_service_identity_from_units

assert "forced identity not overridden"        "$([ "$SERVICE_USER" = "root" ]; echo $?)"
SERVICE_USER_FORCED=false

# ---------------------------------------------------------------------------
echo "==> adoption: skipped in LOCAL_MODE"
LOCAL_MODE=true
SERVICE_USER="someuser"

adopt_service_identity_from_units

assert "local mode untouched"                  "$([ "$SERVICE_USER" = "someuser" ]; echo $?)"
LOCAL_MODE=false

# ---------------------------------------------------------------------------
echo "==> umask preservation"
ENV_BLOCK="Environment=HOME=/home/opencode
Environment=PATH=/usr/local/bin:/usr/bin:/bin"

PRESERVED=$(_preserve_systemd_umask "$UNIT_DIR/kimaki.service" "$ENV_BLOCK")
assert "UMask carried into env block"          "$(echo "$PRESERVED" | grep -q '^UMask=0002$'; echo $?)"
assert "env lines retained alongside UMask"    "$(echo "$PRESERVED" | grep -q '^Environment=HOME=/home/opencode$'; echo $?)"

cat > "$UNIT_DIR/no-umask.service" <<'EOF'
[Service]
User=opencode
Environment=HOME=/home/opencode
EOF
UNCHANGED=$(_preserve_systemd_umask "$UNIT_DIR/no-umask.service" "$ENV_BLOCK")
assert "no UMask -> env block unchanged"       "$([ "$UNCHANGED" = "$ENV_BLOCK" ]; echo $?)"

# ---------------------------------------------------------------------------
echo "==> end-to-end: re-render after adoption keeps User=opencode + UMask"
# Simulate the upgrade flow: root defaults, adoption, then render the kimaki
# unit the way bridge_update_systemd does and assert the #204 diff is gone.
SERVICE_USER="root"
SERVICE_HOME="/root"
KIMAKI_DATA_DIR="/root/.kimaki"
RUN_AS_ROOT=true
adopt_service_identity_from_units

export SITE_PATH="/var/www/site"
export KIMAKI_CONFIG_DIR="/opt/kimaki-config"
export KIMAKI_BIN="/usr/bin/kimaki"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/kimaki.sh"

CURRENT_ENV=$(grep '^Environment=' "$UNIT_DIR/kimaki.service" || true)
MERGED_ENV=$(_preserve_systemd_umask "$UNIT_DIR/kimaki.service" "$CURRENT_ENV")
RENDERED=$(bridge_render_systemd kimaki.service "$MERGED_ENV")

assert "rendered unit keeps User=opencode"     "$(echo "$RENDERED" | grep -q '^User=opencode$'; echo $?)"
assert "rendered unit does NOT flip to root"   "$(echo "$RENDERED" | grep -q '^User=root$'; echo $((1 - $?)))"
assert "rendered unit keeps UMask=0002"        "$(echo "$RENDERED" | grep -q '^UMask=0002$'; echo $?)"
assert "pkill scoped to adopted user"          "$(echo "$RENDERED" | grep -q 'pkill -TERM -u opencode'; echo $?)"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s):$fail_list"
  exit 1
fi
echo "OK: all $PASS service-identity adoption assertions passed"
