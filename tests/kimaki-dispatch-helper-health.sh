#!/bin/bash
# Regression coverage for stale pre-#243 root-owned Kimaki dispatch helpers.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/bridges/_dispatch.sh"
source "$SCRIPT_DIR/bridges/kimaki.sh"

KIMAKI_DISPATCH_WRAPPER_DIR="$TMP/bin"
KIMAKI_DISPATCH_TARGET_DIR="$TMP/lib"
KIMAKI_DISPATCH_SUDOERS_DIR="$TMP/sudoers"
mkdir -p "$KIMAKI_DISPATCH_WRAPPER_DIR" "$KIMAKI_DISPATCH_TARGET_DIR" "$KIMAKI_DISPATCH_SUDOERS_DIR"

LOCAL_MODE=false
SERVICE_USER=opencode
SERVICE_HOME="$TMP/home/opencode"
KIMAKI_DATA_DIR="$SERVICE_HOME/.kimaki"
KIMAKI_BIN="$TMP/kimaki"
KIMAKI_UNIT=kimaki.service
SITE_PATH="$TMP/site"
PATH=/usr/local/bin:/usr/bin:/bin
DRY_RUN=false
UPDATED_ITEMS=()
WP_CODING_AGENTS_TEST_EUID=1000

printf '#!/bin/sh\nprintf "kimaki test\\n"\n' > "$KIMAKI_BIN"
chmod 0755 "$KIMAKI_BIN"

wrapper="$KIMAKI_DISPATCH_WRAPPER_DIR/wp-coding-agents-kimaki-dispatch"
target="$KIMAKI_DISPATCH_TARGET_DIR/kimaki-dispatch-target"
sudoers="$KIMAKI_DISPATCH_SUDOERS_DIR/wp-coding-agents-kimaki-dispatch"

service_home_q=$(_kimaki_shell_quote "$SERVICE_HOME")
data_dir_q=$(_kimaki_shell_quote "$KIMAKI_DATA_DIR")
kimaki_bin_q=$(_kimaki_shell_quote "$KIMAKI_BIN")
path_q=$(_kimaki_shell_quote "$PATH")
target_q=$(_kimaki_shell_quote "$target")
service_user_q=$(_kimaki_shell_quote "$SERVICE_USER")

cat > "$target" <<EOF
#!/bin/sh
set -eu
export HOME=$service_home_q
export KIMAKI_DATA_DIR=$data_dir_q
export PATH=$path_q
exec $kimaki_bin_q "\$@"
EOF
cat > "$wrapper" <<EOF
#!/bin/sh
set -eu
exec sudo -n -H -u $service_user_q $target_q "\$@"
EOF
chmod 0755 "$target" "$wrapper"

# This is the exact pre-#243 stale shape: service-user grant only, no www-data.
printf '%s\n' "opencode ALL=(opencode) NOPASSWD: $target *" > "$sudoers"

_kimaki_install_dispatch_helpers > "$TMP/first.out" 2>&1
first=$(< "$TMP/first.out")
[ "${KIMAKI_DISPATCH_ROOT_REPAIR_REQUIRED:-false}" = true ]
echo "$first" | grep -q '"status":"root_repair_required"'
echo "$first" | grep -q 'sudo -- .*upgrade.sh --kimaki-only --wp-path .* --kimaki-unit kimaki.service'
if echo "$first" | grep -q 'Keeping functional root-owned'; then
  echo "FAIL: pre-#243 helper installation was blessed as healthy" >&2
  exit 1
fi

# Repeated non-root upgrades must continue reporting the unresolved boundary.
KIMAKI_DISPATCH_ROOT_REPAIR_REQUIRED=false
_kimaki_install_dispatch_helpers > "$TMP/second.out" 2>&1
second=$(< "$TMP/second.out")
[ "${KIMAKI_DISPATCH_ROOT_REPAIR_REQUIRED:-false}" = true ]
echo "$second" | grep -q '"status":"root_repair_required"'
if echo "$second" | grep -q 'Keeping functional root-owned'; then
  echo "FAIL: repeated non-root upgrade blessed stale helpers" >&2
  exit 1
fi

generated=$(_kimaki_dispatch_sudoers_content "$SERVICE_USER" "$target")
[ "$(echo "$generated" | grep -c '^www-data ALL=(opencode)')" -eq 1 ]
[ "$(echo "$generated" | grep -c '^opencode ALL=(opencode)')" -eq 1 ]
deduped=$(_kimaki_dispatch_sudoers_content www-data "$target")
[ "$(echo "$deduped" | grep -c '^www-data ALL=(www-data)')" -eq 1 ]

# Caller validation exercises the scheduled web user and service user once each,
# while a www-data service identity remains deduplicated.
callers_file="$TMP/callers"
_kimaki_dispatch_caller_can_execute() {
  printf '%s\n' "$1" >> "$callers_file"
}
_kimaki_validate_dispatch_callers "$wrapper" opencode
[ "$(grep -c '^www-data$' "$callers_file")" -eq 1 ]
[ "$(grep -c '^opencode$' "$callers_file")" -eq 1 ]
: > "$callers_file"
_kimaki_validate_dispatch_callers "$wrapper" www-data
[ "$(grep -c '^www-data$' "$callers_file")" -eq 1 ]

# Root rewrites all three artifacts from current generated content and validates
# both caller paths. The caller probe remains stubbed; content checks stay real.
chown() { return 0; }
WP_CODING_AGENTS_TEST_EUID=0
_kimaki_install_dispatch_helpers >/dev/null

expected_sudoers=$(_kimaki_dispatch_sudoers_content "$SERVICE_USER" "$target")
printf '%s\n' "$expected_sudoers" | cmp -s - "$sudoers"
grep -q '^www-data ALL=(opencode)' "$sudoers"
grep -q '^opencode ALL=(opencode)' "$sudoers"

echo "PASS: tests/kimaki-dispatch-helper-health.sh"
