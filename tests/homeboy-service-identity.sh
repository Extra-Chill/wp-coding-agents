#!/bin/bash
# Service-owned Homeboy contract for managed non-root setup and upgrade.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT/lib/common.sh"
source "$ROOT/lib/homeboy.sh"
source "$ROOT/guidance/homeboy.sh"

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }

SERVICE_HOME="$TMP/service"
SERVICE_USER="$(command id -un)"
LOCAL_MODE=false
EXTERNAL_WORDPRESS=false
DRY_RUN=false
SYSTEM_BIN="$TMP/usr-local-homeboy"
export WP_CODING_AGENTS_HOMEBOY_SYSTEM_BIN="$SYSTEM_BIN"
mkdir -p "$TMP"
printf '#!/bin/sh\nprintf service\n' > "$SYSTEM_BIN"
chmod 0755 "$SYSTEM_BIN"

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
chown() { CHOWN_ARGS="$*"; CHOWN_CALLS=$((CHOWN_CALLS + 1)); :; }
run_cmd() { "$@"; }
log() { :; }
error() { fail "$*"; }

homeboy_provision_service_bin
TARGET="$SERVICE_HOME/.local/bin/homeboy"
[ -x "$TARGET" ] || fail "system Homeboy was not copied to SERVICE_HOME/.local/bin"
[ -d "$SERVICE_HOME/.local/bin" ] || fail "service-owned bin parent was not created"
[ -d "$SERVICE_HOME/.local" ] || fail "service-owned .local parent was not created"
case " $CHOWN_ARGS " in *" $SERVICE_USER:$SERVICE_USER $SERVICE_HOME/.local $SERVICE_HOME/.local/bin $TARGET"*) ;; *) fail "ownership convergence missed owner, parent, bin, or executable: $CHOWN_ARGS" ;; esac
[ "$CHOWN_CALLS" -eq 1 ] || fail "new installation did not converge ownership"
[ "$(homeboy_bin)" = "$TARGET" ] || fail "service-owned Homeboy was not preferred"
ok "new install assigns service ownership to .local, bin, and executable"

[ "$(_guidance_homeboy_service_bin_path)" = "$TARGET" ] || fail "guidance did not resolve SERVICE_HOME/.local/bin"
first_guidance_candidate=""
while IFS= read -r first_guidance_candidate; do break; done < <(_guidance_homeboy_bin_candidates)
[ "$first_guidance_candidate" = "$TARGET" ] || fail "guidance did not prefer the service-owned binary"
ok "dynamic guidance follows the service-owned binary"

printf 'newer-service-copy\n' > "$TARGET"
chmod 0755 "$TARGET"
CHOWN_CALLS=0
homeboy_provision_service_bin
[ "$(cat "$TARGET")" = newer-service-copy ] || fail "newer service-owned copy was overwritten"
case " $CHOWN_ARGS " in *" $SERVICE_USER:$SERVICE_USER $SERVICE_HOME/.local $SERVICE_HOME/.local/bin $TARGET"*) ;; *) fail "existing executable ownership was not repaired" ;; esac
[ "$CHOWN_CALLS" -eq 1 ] || fail "existing executable path was not re-converged"
ok "existing executable and both parents are re-owned without replacing its contents"

sudo() { printf '%s\n' "$*" > "$TMP/sudo-argv"; return 0; }
export WP_CODING_AGENTS_TEST_ASSUME_ROOT=true
homeboy_run --version
grep -Fq -- "$TARGET --version" "$TMP/sudo-argv" || fail "homeboy_run did not use the service-owned absolute path"
grep -Fq -- "PATH=$SERVICE_HOME/.local/bin:$PATH" "$TMP/sudo-argv" || fail "service-user Homeboy child PATH does not prefer the service bin"
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
