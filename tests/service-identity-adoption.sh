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
# Issue #232: KIMAKI_BIN / PATH must follow the ADOPTED service identity, not
# the invoking shell. Reproduces the production trap: upgrade runs as root,
# adoption flips SERVICE_USER to opencode, but `which kimaki` would resolve
# /root/.kimaki/bin/kimaki — an ExecStart the opencode service user can't read.
echo "==> #232: binary resolution follows adopted identity (root invoker + opencode unit)"

# Adopt opencode from the unit (root defaults -> opencode), exactly as above.
SERVICE_USER="root"
SERVICE_HOME="/root"
KIMAKI_DATA_DIR="/root/.kimaki"
RUN_AS_ROOT=true
adopt_service_identity_from_units

# Sandbox so the resolver's system-prefix probe and SERVICE_HOME fallback are
# deterministic and offline (no real /usr/bin/kimaki, no sudo). SERVICE_HOME
# is redirected into the temp dir so the per-user fallback is writable.
BIN232="$TMP/bin232"
ADOPTED_HOME="$TMP/home-opencode"
mkdir -p "$BIN232" "$ADOPTED_HOME/.kimaki/bin"
SERVICE_HOME="$ADOPTED_HOME"
KIMAKI_DATA_DIR="$ADOPTED_HOME/.kimaki"
# Per-user install layout under the ADOPTED (non-root) home.
printf '#!/bin/sh\n' > "$ADOPTED_HOME/.kimaki/bin/kimaki"
chmod +x "$ADOPTED_HOME/.kimaki/bin/kimaki"

# No system-prefix binary exists in this sandbox (yet).
export KIMAKI_SYSTEM_PREFIX_BINS="$BIN232/usr-bin-kimaki $BIN232/usr-local-kimaki"
# Force the "invoking user != service user, running as root" branch. Build a
# clean PATH containing only the coreutils the test needs — crucially WITHOUT
# `sudo` and WITHOUT `kimaki`, so resolver step 2 (sudo probe) is skipped and
# resolution falls through to the SERVICE_HOME per-user binary, deterministic
# and offline on any machine.
CLEANBIN="$TMP/cleanbin"
mkdir -p "$CLEANBIN"
for tool in bash mkdir rm chmod grep cat dirname id printf env; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] && ln -sf "$tool_path" "$CLEANBIN/$tool"
done
export WP_CODING_AGENTS_TEST_ASSUME_ROOT=true
LOCAL_MODE=false
PATH_SAVE="$PATH"
export PATH="$CLEANBIN"

RESOLVED_BIN=$(_kimaki_resolve_service_bin "/usr/bin/kimaki")
assert "resolved bin is under adopted SERVICE_HOME" \
  "$([ "$RESOLVED_BIN" = "$ADOPTED_HOME/.kimaki/bin/kimaki" ]; echo $?)"
assert "resolved bin is NOT under /root" \
  "$(case "$RESOLVED_BIN" in /root/*) echo 1 ;; *) echo 0 ;; esac)"

# A real system-prefix binary wins over the per-user home (issue option 1).
printf '#!/bin/sh\n' > "$BIN232/usr-bin-kimaki"
chmod +x "$BIN232/usr-bin-kimaki"
RESOLVED_SYS=$(_kimaki_resolve_service_bin "/usr/bin/kimaki")
assert "system-prefix binary preferred over per-user home" \
  "$([ "$RESOLVED_SYS" = "$BIN232/usr-bin-kimaki" ]; echo $?)"

export PATH="$PATH_SAVE"
unset KIMAKI_SYSTEM_PREFIX_BINS WP_CODING_AGENTS_TEST_ASSUME_ROOT

# Guard: _kimaki_assert_bin_identity warns when the binary / PATH segment
# references a different user's home than the adopted SERVICE_HOME.
echo "==> #232: identity guard warns on a /root binary under an opencode unit"
SERVICE_USER="opencode"
SERVICE_HOME="/home/opencode"
GUARD_BAD=$(_kimaki_assert_bin_identity \
  "/root/.kimaki/bin/kimaki" \
  "/root/.kimaki/bin:/home/opencode/.kimaki/bin:/usr/bin:/bin" 2>&1)
assert "guard warns on /root ExecStart binary" \
  "$(echo "$GUARD_BAD" | grep -q 'NOT under SERVICE_HOME'; echo $?)"
assert "guard warns on /root PATH segment" \
  "$(echo "$GUARD_BAD" | grep -q "PATH segment '/root/.kimaki/bin'"; echo $?)"

GUARD_OK=$(_kimaki_assert_bin_identity \
  "/home/opencode/.kimaki/bin/kimaki" \
  "/home/opencode/.kimaki/bin:/usr/bin:/bin" 2>&1)
assert "guard silent on consistent opencode identity" \
  "$([ -z "$GUARD_OK" ]; echo $?)"

GUARD_SYS=$(_kimaki_assert_bin_identity "/usr/bin/kimaki" "/usr/bin:/bin" 2>&1)
assert "guard silent on system-prefix binary" \
  "$([ -z "$GUARD_SYS" ]; echo $?)"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s):$fail_list"
  exit 1
fi
echo "OK: all $PASS service-identity adoption assertions passed"
