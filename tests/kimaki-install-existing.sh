#!/bin/bash
# An installed Kimaki may keep running after printing --version. Detection must
# not launch it just to decorate setup logs.
#
# #580: managed non-root VPS installs provision Kimaki into a SERVICE_HOME
# prefix as SERVICE_USER. Root, local, and external WordPress installs keep
# the global `npm install -g kimaki` layout.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

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

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label"
    echo "       expected: '$expected'"
    echo "       actual:   '$actual'"
    FAIL=$((FAIL + 1))
    fail_list="$fail_list
  - $label"
  fi
}

cat > "$TMP/bin/kimaki" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  touch "$TEST_TMP/version-invoked"
  sleep 30
fi
SH
chmod +x "$TMP/bin/kimaki"

export TEST_TMP="$TMP"
export PATH="$TMP/bin:/usr/bin:/bin"
export DRY_RUN=false
export EXTERNAL_WORDPRESS=true
export LOCAL_MODE=false
export PLATFORM=linux
unset KIMAKI_BOT_TOKEN

log() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; exit 1; }
run_cmd() { "$@"; }
external_wordpress_kimaki_command() { printf 'kimaki'; }

# shellcheck disable=SC1091
source "$ROOT/bridges/kimaki.sh"
_kimaki_sync_bin_helpers() { :; }

echo "==> existing install is not probed with --version"
bridge_install
assert "did not invoke kimaki --version" "$([ ! -e "$TMP/version-invoked" ]; echo $?)"

# ---------------------------------------------------------------------------
echo "==> #580: managed non-root install runs as the service user"

SERVICE_HOME="$TMP/home-opencode"
SERVICE_USER="opencode"
KIMAKI_DATA_DIR="$SERVICE_HOME/.kimaki"
EXTERNAL_WORDPRESS=false
LOCAL_MODE=false
DRY_RUN=false
mkdir -p "$SERVICE_HOME"
rm -rf "$SERVICE_HOME/.local"
: > "$TMP/sudo.log"
: > "$TMP/npm.log"

sudo() {
  printf 'sudo %s\n' "$*" >> "$TMP/sudo.log"
  local prefix="" arg
  for arg in "$@"; do
    case "$arg" in
      npm_config_prefix=*) prefix="${arg#npm_config_prefix=}" ;;
    esac
  done
  printf 'npm install -g kimaki\n' >> "$TMP/npm.log"
  [ -n "$prefix" ] || return 0
  mkdir -p "$prefix/bin"
  printf '#!/bin/sh\n' > "$prefix/bin/kimaki"
  chmod +x "$prefix/bin/kimaki"
}

npm() {
  printf 'npm %s\n' "$*" >> "$TMP/npm.log"
}

export WP_CODING_AGENTS_TEST_ASSUME_ROOT=true
_kimaki_provision_package

prefix="$SERVICE_HOME/.local"
assert "service-owned prefix binary installed" "$([ -x "$prefix/bin/kimaki" ]; echo $?)"
assert "install hopped to SERVICE_USER" "$(grep -q "sudo -n -H -u opencode " "$TMP/sudo.log"; echo $?)"
assert "install set npm_config_prefix to SERVICE_HOME/.local" \
  "$(grep -q "npm_config_prefix=$prefix" "$TMP/sudo.log"; echo $?)"
assert "install invoked npm install -g kimaki" "$(grep -q "npm install -g kimaki" "$TMP/npm.log"; echo $?)"
assert "did not install into a system prefix" \
  "$(grep -q "npm_config_prefix=/usr" "$TMP/sudo.log"; echo $((1 - $?)))"

# ---------------------------------------------------------------------------
echo "==> #580: rendered environment and binary prefer the service-owned prefix"

resolved="$(_kimaki_resolve_service_bin /usr/bin/kimaki)"
assert_eq "ExecStart binary is service-owned" "$prefix/bin/kimaki" "$resolved"

prefix_env="$(_kimaki_npm_config_prefix_env)"
assert_eq "unit sets npm_config_prefix" \
  "Environment=npm_config_prefix=$prefix" "$(printf '%s' "$prefix_env" | tr -d '\n')"

# A root-global binary must not win over the service-owned prefix.
sys_bin="$TMP/usr-bin-kimaki"
printf '#!/bin/sh\n' > "$sys_bin"
chmod +x "$sys_bin"
export KIMAKI_SYSTEM_PREFIX_BINS="$sys_bin"
resolved_with_global="$(_kimaki_resolve_service_bin /usr/bin/kimaki)"
assert_eq "service-owned binary preferred over system-prefix" \
  "$prefix/bin/kimaki" "$resolved_with_global"
unset KIMAKI_SYSTEM_PREFIX_BINS

path_value="$prefix/bin:/usr/local/bin:/usr/bin:/bin"
assert_eq "resolved bin dir is the service-owned prefix" \
  "$prefix/bin" "$(dirname "$resolved")"

SITE_PATH="$TMP/site"
KIMAKI_CONFIG_DIR="$TMP/kimaki-config"
KIMAKI_BIN="$resolved"
KIMAKI_UNIT="kimaki.service"
mkdir -p "$SITE_PATH" "$KIMAKI_CONFIG_DIR"
_kimaki_skill_filter_args_shell() { printf ''; }
_kimaki_datamachine_wp_transport_systemd_env() { printf 'Environment=DATAMACHINE_WP_TRANSPORT_JSON="[\"wp\"]"\n'; }
ENV_BLOCK="Environment=HOME=$SERVICE_HOME
Environment=PATH=$path_value
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR
$(_kimaki_npm_config_prefix_env)"
rendered="$(bridge_render_systemd kimaki.service "$ENV_BLOCK")"
assert "rendered ExecStart uses service-owned binary" \
  "$(printf '%s\n' "$rendered" | grep -q "^ExecStart=$prefix/bin/kimaki "; echo $?)"
assert "rendered env keeps npm_config_prefix" \
  "$(printf '%s\n' "$rendered" | grep -q "^Environment=npm_config_prefix=$prefix$"; echo $?)"
assert "rendered PATH starts with service-owned bin" \
  "$(printf '%s\n' "$rendered" | grep -q "^Environment=PATH=$prefix/bin:"; echo $?)"

# ---------------------------------------------------------------------------
echo "==> #580: upgrade convergence is idempotent and does not change identity"

: > "$TMP/sudo.log"
: > "$TMP/npm.log"
saved_user="$SERVICE_USER"
saved_home="$SERVICE_HOME"
_kimaki_provision_package
assert "second provision skips npm when prefix binary exists" \
  "$([ ! -s "$TMP/npm.log" ]; echo $?)"
assert "SERVICE_USER unchanged" "$([ "$SERVICE_USER" = "$saved_user" ]; echo $?)"
assert "SERVICE_HOME unchanged" "$([ "$SERVICE_HOME" = "$saved_home" ]; echo $?)"

rm -f "$prefix/bin/kimaki"
: > "$TMP/sudo.log"
: > "$TMP/npm.log"
_kimaki_provision_package
assert "missing prefix binary converges with a service-user install" \
  "$(grep -q "sudo -n -H -u opencode " "$TMP/sudo.log" && [ -x "$prefix/bin/kimaki" ]; echo $?)"

# Same adopted home, second instance: same prefix.
KIMAKI_UNIT="kimaki-site-b.service"
assert_eq "multi-instance prefix follows SERVICE_HOME" \
  "$SERVICE_HOME/.local" "$(_kimaki_service_npm_prefix)"
KIMAKI_UNIT="kimaki.service"

# ---------------------------------------------------------------------------
echo "==> #580: root-service and local installs keep global npm -g"

unset WP_CODING_AGENTS_TEST_ASSUME_ROOT
: > "$TMP/sudo.log"
: > "$TMP/npm.log"
: > "$TMP/global.log"
npm() {
  printf 'npm %s\n' "$*" >> "$TMP/npm.log"
  printf 'npm %s\n' "$*" >> "$TMP/global.log"
}

SERVICE_USER="root"
SERVICE_HOME="/root"
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
DRY_RUN=true
_kimaki_provision_package
assert "root-service uses npm install -g without a user prefix" \
  "$(grep -qx "npm install -g kimaki" "$TMP/global.log"; echo $?)"
assert "root-service does not sudo -u a service user" \
  "$([ ! -s "$TMP/sudo.log" ]; echo $?)"
assert "root-service does not set npm_config_prefix" \
  "$(grep -q npm_config_prefix "$TMP/global.log"; echo $((1 - $?)))"
assert_eq "root-service leaves npm_config_prefix env unset" \
  "" "$(_kimaki_npm_config_prefix_env | tr -d '\n')"

sys_bin="$TMP/usr-bin-kimaki"
export KIMAKI_SYSTEM_PREFIX_BINS="$sys_bin"
assert_eq "root-service prefers system-prefix binary" \
  "$sys_bin" "$(_kimaki_resolve_service_bin /usr/bin/kimaki)"
unset KIMAKI_SYSTEM_PREFIX_BINS

: > "$TMP/sudo.log"
: > "$TMP/global.log"
SERVICE_USER="$(id -un)"
SERVICE_HOME="$HOME"
LOCAL_MODE=true
EXTERNAL_WORDPRESS=false
DRY_RUN=true
_kimaki_provision_package
assert "local mode uses npm install -g without a user prefix" \
  "$(grep -qx "npm install -g kimaki" "$TMP/global.log"; echo $?)"
assert "local mode does not sudo -u a service user" \
  "$([ ! -s "$TMP/sudo.log" ]; echo $?)"
assert_eq "local mode leaves npm_config_prefix env unset" \
  "" "$(_kimaki_npm_config_prefix_env | tr -d '\n')"

: > "$TMP/sudo.log"
: > "$TMP/global.log"
LOCAL_MODE=false
EXTERNAL_WORDPRESS=true
SERVICE_USER="opencode"
SERVICE_HOME="$TMP/home-opencode"
DRY_RUN=true
_kimaki_provision_package
assert "external WordPress uses npm install -g without a service prefix" \
  "$(grep -qx "npm install -g kimaki" "$TMP/global.log"; echo $?)"
assert_eq "external WordPress leaves npm_config_prefix env unset" \
  "" "$(_kimaki_npm_config_prefix_env | tr -d '\n')"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: $FAIL assertion(s):$fail_list"
  exit 1
fi
echo "OK: all $PASS kimaki install assertions passed"
echo "PASS: tests/kimaki-install-existing.sh"
