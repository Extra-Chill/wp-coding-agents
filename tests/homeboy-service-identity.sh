#!/bin/bash
# Service-owned Homeboy contract for managed non-root setup and upgrade.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT/lib/common.sh"
source "$ROOT/lib/homeboy.sh"
source "$ROOT/guidance/homeboy.sh"
eval "$(declare -f file_owner | sed '1s/file_owner/_homeboy_test_real_file_owner/')"
MOCK_ROOT_PREFIX_OWNER=true
MOCK_TARGET_OWNER=""
file_owner() {
  case "$1" in
    "$TMP"|"$TMP/wp-coding-agents"|"$TMP/untrusted-system"|"$TMP/unsafe-mode-parent")
      if [ "$MOCK_ROOT_PREFIX_OWNER" = true ]; then printf 'root\n'; else _homeboy_test_real_file_owner "$@"; fi
      ;;
    "$TMP/restrict-parent"|"$TMP/restrict-parent/wp-coding-agents") printf 'root\n' ;;
    "$TMP/wp-coding-agents/bin")
      if [ "$MOCK_ROOT_PREFIX_OWNER" = true ]; then printf '%s\n' "$SERVICE_USER"; else _homeboy_test_real_file_owner "$@"; fi
      ;;
    "$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN")
      if [ -n "$MOCK_TARGET_OWNER" ]; then printf '%s\n' "$MOCK_TARGET_OWNER"; else _homeboy_test_real_file_owner "$@"; fi
      ;;
    *) _homeboy_test_real_file_owner "$@" ;;
  esac
}

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }

SERVICE_HOME="$TMP/service"
SERVICE_USER="$(command id -un)"
[ "$SERVICE_USER" != root ] || SERVICE_USER="opencode"
WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$TMP/wp-coding-agents/bin/homeboy"
export WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
DRY_RUN=false
SYSTEM_BIN="$TMP/usr-local-homeboy"
export WP_CODING_AGENTS_HOMEBOY_SYSTEM_BIN="$SYSTEM_BIN"
mkdir -p "$TMP"
printf '#!/bin/sh\nprintf service\n' > "$SYSTEM_BIN"
chmod 0755 "$SYSTEM_BIN"
UNSAFE_HOME_BIN="$SERVICE_HOME/.local/bin/homeboy"
mkdir -p "$(dirname "$UNSAFE_HOME_BIN")"
if homeboy_managed_prefix_safe "$UNSAFE_HOME_BIN"; then fail "accepted managed Homeboy inside SERVICE_HOME"; fi
mkdir -p "$TMP/private/wp-coding-agents/bin"
if homeboy_managed_prefix_safe "$TMP/private/wp-coding-agents/bin/homeboy"; then fail "accepted a prefix below an untrusted user-owned parent"; fi
mkdir -p "$TMP/untrusted-system/wp-coding-agents/bin"
if [ "$(command id -u)" -eq 0 ]; then
  NONROOT_OWNER="nobody"
  command id -u "$NONROOT_OWNER" >/dev/null 2>&1 || NONROOT_OWNER="daemon"
  command chown "$NONROOT_OWNER" "$TMP/untrusted-system/wp-coding-agents"
fi
if homeboy_managed_prefix_safe "$TMP/untrusted-system/wp-coding-agents/bin/homeboy"; then fail "accepted an existing user-owned managed prefix"; fi
mkdir -p "$TMP/unsafe-mode-parent/wp-coding-agents/bin"
chmod 0777 "$TMP/unsafe-mode-parent/wp-coding-agents"
if homeboy_managed_prefix_safe "$TMP/unsafe-mode-parent/wp-coding-agents/bin/homeboy"; then fail "accepted a writable managed prefix"; fi
mkdir -p "$TMP/symlink-prefix"
ln -s "$TMP/wp-coding-agents" "$TMP/symlink-prefix/wp-coding-agents"
if homeboy_managed_prefix_safe "$TMP/symlink-prefix/wp-coding-agents/bin/homeboy"; then fail "accepted a symlinked managed prefix"; fi
ok "unsafe SERVICE_HOME, untrusted ownership/modes, and symlinked paths are rejected before mutation"

# Keep the fixture independent of the account running the test.
id() {
  case "${1:-}" in
    -u) [ "${2:-}" = "$SERVICE_USER" ] && printf '1001' || printf '0' ;;
    -gn) printf '%s' "$SERVICE_USER" ;;
    -un) printf 'root' ;;
    *) printf '0' ;;
  esac
}
install() { cp "$3" "$4"; chmod 0755 "$4"; }
CHOWN_ARGS=""
CHOWN_CALLS=0
CHOWN_LOG=""
ROOT_MUTATION_LOG=""
SUDO_LOG=""
chown() {
  CHOWN_ARGS="$*"
  CHOWN_LOG+="$*"$'\n'
  CHOWN_CALLS=$((CHOWN_CALLS + 1))
  if [ "$(command id -u)" -eq 0 ]; then
    case "$1" in
      root:root) command chown "$@" ;;
      *) command id -u "${1%%:*}" >/dev/null 2>&1 && command chown "$@" || true ;;
    esac
  fi
}
run_cmd() {
  ROOT_MUTATION_LOG+="$*"$'\n'
  "$@"
}
sudo() {
  SUDO_LOG+="$*"$'\n'
  while [ "$#" -gt 0 ] && [ "$1" != env ]; do shift; done
  [ "${1:-}" = env ] || return 1
  shift
  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do shift; done
  "$@"
  local status=$?
  MOCK_TARGET_OWNER="$SERVICE_USER"
  return "$status"
}
log() { :; }
error() { fail "$*"; }

RESTRICTED_PREFIX="$TMP/restrict-parent/wp-coding-agents"
mkdir -p "$RESTRICTED_PREFIX"
chmod 0700 "$RESTRICTED_PREFIX"
RESTRICTED_MESSAGE="$( (WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN="$RESTRICTED_PREFIX/bin/homeboy"; export WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN; homeboy_provision_service_bin) 2>&1 || true)"
case "$RESTRICTED_MESSAGE" in *"$RESTRICTED_PREFIX"*"inspect its contents"*"root:root 0755"*) ;; *) fail "restrictive existing prefix did not fail with exact remediation: $RESTRICTED_MESSAGE" ;; esac
[ ! -e "$RESTRICTED_PREFIX/bin" ] || fail "restrictive existing prefix was mutated"
ok "existing restrictive prefix is refused without chmod or child creation"

mkdir -p "$SERVICE_HOME/.local/bin"
printf '#!/bin/sh\nprintf legacy\n' > "$SERVICE_HOME/.local/bin/homeboy"
chmod 0755 "$SERVICE_HOME/.local/bin/homeboy"
OLD_UMASK="$(umask)"
umask 077
homeboy_provision_service_bin
umask "$OLD_UMASK"
TARGET="$WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN"
[ -x "$TARGET" ] || fail "service Homeboy was not seeded into managed bin"
[ -d "$(dirname "$TARGET")" ] || fail "managed bin parent was not created"
case " $ROOT_MUTATION_LOG " in *"mkdir -m 0700 $(dirname "$(dirname "$TARGET")")"*) ;; *) fail "root did not create the managed prefix before handoff: $ROOT_MUTATION_LOG" ;; esac
case " $CHOWN_LOG " in *"$SERVICE_USER:$SERVICE_USER $(dirname "$TARGET")"*) ;; *) fail "ownership convergence missed the service-owned bin: $CHOWN_LOG" ;; esac
[ "$CHOWN_CALLS" -eq 1 ] || fail "new installation did not hand off only the managed bin directory"
case "$ROOT_MUTATION_LOG" in *"$TARGET"*) fail "root mutation reached the service-writable executable: $ROOT_MUTATION_LOG" ;; esac
case "$ROOT_MUTATION_LOG" in *"$(dirname "$TARGET")"*) ;; *) fail "root did not establish ownership of the managed bin before handoff" ;; esac
case "$SUDO_LOG" in *"-u $SERVICE_USER env HOME=$SERVICE_HOME"*"/bin/bash -c"*) ;; *) fail "binary install/permission convergence did not run through the service identity: $SUDO_LOG" ;; esac
[ "$(file_mode "$(dirname "$(dirname "$TARGET")")")" = 755 ] || fail "freshly created managed prefix is not traversable after umask 077"
if [ "$(command id -u)" -eq 0 ]; then
  [ "$(_homeboy_test_real_file_owner "$(dirname "$(dirname "$TARGET")")")" = root ] || fail "managed prefix ancestor is not root-owned"
fi
[ "$(cat "$TARGET")" = "$(cat "$SERVICE_HOME/.local/bin/homeboy")" ] || fail "legacy service binary was not preferred as seed"
[ "$(file_mode "$(dirname "$TARGET")")" = 755 ] || fail "managed bin is not world-traversable"
[ "$(file_mode "$TARGET")" = 755 ] || fail "managed binary mode is not 755"
if [ "$(command id -u)" -eq 0 ] && command id -u "$SERVICE_USER" >/dev/null 2>&1; then
  su -s /bin/sh "$SERVICE_USER" -c "test -w '$(dirname "$TARGET")'" 2>/dev/null || fail "service user cannot replace the managed executable"
else
  [ -w "$(dirname "$TARGET")" ] || fail "service user cannot replace the managed executable"
fi
[ "$(homeboy_bin)" = "$TARGET" ] || fail "service-owned Homeboy was not preferred"
ok "new install seeds a shared executable directory with bounded ownership"

[ "$(_guidance_homeboy_service_bin_path)" = "$TARGET" ] || fail "guidance did not resolve managed bin"
COMPOSE_USER="www-data"
if [ "$COMPOSE_USER" = "$SERVICE_USER" ]; then COMPOSE_USER="nobody"; fi
if command -v getent >/dev/null 2>&1 && ! getent passwd "$COMPOSE_USER" >/dev/null; then COMPOSE_USER="nobody"; fi
if [ "$(uname -s)" = Linux ]; then
  chmod o+x "$TMP"
else
  COMPOSE_USER="$(command id -un)"
fi
unset -f id
MOCK_ROOT_PREFIX_OWNER=false
WP_CODING_AGENTS_COMPOSE_USER="$COMPOSE_USER"
export WP_CODING_AGENTS_COMPOSE_USER
_guidance_homeboy_reachable_by_compose "$TARGET" || fail "compose identity cannot reach managed Homeboy"
id() {
  case "${1:-}" in
    -u) [ "${2:-}" = "$SERVICE_USER" ] && printf '1001' || printf '0' ;;
    -gn) printf '%s' "$SERVICE_USER" ;;
    -un) printf 'root' ;;
    *) printf '0' ;;
  esac
}
MOCK_ROOT_PREFIX_OWNER=true
first_guidance_candidate=""
while IFS= read -r first_guidance_candidate; do break; done < <(_guidance_homeboy_bin_candidates)
[ "$first_guidance_candidate" = "$TARGET" ] || fail "guidance did not prefer the service-owned binary"
ok "dynamic guidance follows the service-owned binary"

printf 'older-root-system-copy\n' > "$SYSTEM_BIN"
printf 'current-root-owned-managed-copy\n' > "$TARGET"
chmod 0755 "$TARGET"
MOCK_TARGET_OWNER=root
ROOT_MUTATION_LOG=""
homeboy_provision_service_bin
[ "$(cat "$TARGET")" = current-root-owned-managed-copy ] || fail "root-owned current binary was replaced with an older seed"
[ "$(file_owner "$TARGET")" = "$SERVICE_USER" ] || fail "existing root-owned executable was not atomically taken into service ownership"
case "$ROOT_MUTATION_LOG" in *"$TARGET"*|*"$(dirname "$TARGET")"*) fail "root mutated the existing service bin/executable: $ROOT_MUTATION_LOG" ;; esac
ok "root-owned mode-755 binary is atomically replaced as the service user with identical content"

printf 'newer-managed-copy\n' > "$TARGET"
chmod 0755 "$TARGET"
MOCK_TARGET_OWNER="$SERVICE_USER"
CHOWN_CALLS=0
ROOT_MUTATION_LOG=""
homeboy_provision_service_bin
[ "$(cat "$TARGET")" = newer-managed-copy ] || fail "managed binary was overwritten"
case "$ROOT_MUTATION_LOG" in *"$(dirname "$TARGET")"*|*"$TARGET"*) fail "repeat root provisioning mutated service-writable bin contents: $ROOT_MUTATION_LOG" ;; esac
[ "$CHOWN_CALLS" -eq 0 ] || fail "repeat provisioning chowned the service-owned bin"
ok "newer service-owned managed executable remains untouched on repeat provisioning"

source "$ROOT/bridges/_dispatch.sh"
SERVICE_PATH="$(_compose_path_value "$(dirname "$TARGET")" "$SERVICE_HOME/.local/bin" /usr/bin /bin)"
RESOLVED_HOMEBoy="$(PATH="$SERVICE_PATH" command -v homeboy)"
[ "$RESOLVED_HOMEBoy" = "$TARGET" ] || fail "service PATH resolves $RESOLVED_HOMEBoy instead of the managed binary"
ok "managed binary wins PATH over legacy service and older system copies"

sudo() { printf '%s\n' "$*" > "$TMP/sudo-argv"; return 0; }
export WP_CODING_AGENTS_TEST_ASSUME_ROOT=true
homeboy_run --version
grep -Fq -- "$TARGET --version" "$TMP/sudo-argv" || fail "homeboy_run did not use the service-owned absolute path"
grep -Fq -- "PATH=$(dirname "$TARGET"):$PATH" "$TMP/sudo-argv" || fail "service-user Homeboy child PATH does not prefer managed bin"
ok "homeboy_run drops to the service identity before execution"

SERVICE_USER=root
SERVICE_HOME=/root
[ "$(homeboy_bin)" = "$SYSTEM_BIN" ] || fail "root mode stopped using the system binary"
LOCAL_MODE=true
[ "$(homeboy_bin)" = "$SYSTEM_BIN" ] || fail "local mode stopped using the system binary"
EXTERNAL_WORDPRESS=true
LOCAL_MODE=false
[ "$(homeboy_bin)" = "$SYSTEM_BIN" ] || fail "external mode stopped using the system binary"
ok "root, local, and external modes retain global resolution"

printf 'OK: all %s Homeboy service-identity assertions passed\n' "$PASS"
