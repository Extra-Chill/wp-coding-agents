#!/bin/bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/site"
printf '%s\n' 'old guidance' > "$WORK/site/AGENTS.md"

cat > "$WORK/bin/sudo" <<'STUB'
#!/bin/bash
[[ "${WP_CODING_AGENTS_TEST_ASSUME_ROOT:-false}" = true ]] || exit 1
printf '%s\n' "$*" > "$SUDO_LOG"
while [ "$1" != "-u" ]; do shift; done
shift 2
while [ "$1" = env ]; do shift; done
if [ "$1" = test ]; then [ "${MOCK_OWNER_WRITABLE:-true}" = true ]; exit $?; fi
while [[ "$1" == *=* ]]; do shift; done
if [ "${MOCK_COMPOSE_FAIL:-false}" = true ]; then printf 'credential=never-display\n' >&2; exit 7; fi
"$@"
STUB
cat > "$WORK/bin/wp" <<'STUB'
#!/bin/bash
site="$(pwd)"
tmp="${site}/.compose.$$"
printf '%s\n' 'updated guidance' > "$tmp"
mv "$tmp" "$site/AGENTS.md"
STUB
chmod +x "$WORK/bin/sudo" "$WORK/bin/wp"

export PATH="$WORK/bin:$PATH" SITE_PATH="$WORK/site" SERVICE_USER=opencode
export SERVICE_HOME="$WORK/service-home" LOCAL_MODE=false
export WP_CODING_AGENTS_COMPOSE_USER=www-data MOCK_SITE_OWNER=www-data
export MOCK_OWNER_WRITABLE=true MOCK_COMPOSE_FAIL=false
export WP_CODING_AGENTS_TEST_ASSUME_ROOT=true SUDO_LOG="$WORK/sudo.log"
export WP_CALL_LOG="$WORK/wp-call.log"
WP_CLI_TRANSPORT=(wp)
WP_ROOT_FLAG=--allow-root
DRY_RUN=false
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/wordpress.sh"
wp_cli_transport_ensure() { WP_CLI_TRANSPORT=(wp); }
wp_cli() { printf '%s\n' "$*" > "$WP_CALL_LOG"; wp "$@"; }
wp_run_as_service_user() { return 99; }
file_owner() { printf '%s' "$MOCK_SITE_OWNER"; }
id() {
  if [ "${WP_CODING_AGENTS_TEST_ASSUME_ROOT:-false}" = true ]; then
    case "$1" in -u) printf '0\n'; return ;; -un) printf 'root\n'; return ;; esac
  fi
  command id "$@"
}

(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md)
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
[[ "$(<"$SUDO_LOG")" == *'-u www-data'* ]]
[[ ! -e "$WORK/site/.compose."* ]]
echo 'ok   root composes atomically as SITE_PATH owner, not service user'

SERVICE_USER=www-data
(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md)
[[ "$(<"$SUDO_LOG")" == *"HOME=$SERVICE_HOME"* ]]
echo 'ok   site-owner route preserves configured service HOME'
SERVICE_USER=opencode

MOCK_SITE_OWNER=other-owner
if output="$(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md 2>&1)"; then
  echo 'FAIL mismatched compose override unexpectedly composed' >&2
  exit 1
fi
[[ "$output" == *'[compose_identity_mismatch]'* ]]
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
echo 'ok   compose override mismatch fails closed without changing guidance'
MOCK_SITE_OWNER=www-data

SERVICE_USER=opencode MOCK_SITE_OWNER=root WP_CODING_AGENTS_COMPOSE_USER=root
if output="$(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md 2>&1)"; then
  echo 'FAIL root-owned site composed for non-root managed service' >&2
  exit 1
fi
[[ "$output" == *'[root_owned_site_for_nonroot_service]'* ]]
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
echo 'ok   root-owned site fails closed for non-root managed service'
SERVICE_USER=opencode
WP_CODING_AGENTS_COMPOSE_USER=www-data
MOCK_SITE_OWNER=www-data

MOCK_OWNER_WRITABLE=false
if output="$(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md 2>&1)"; then
  echo 'FAIL non-writable owner directory unexpectedly composed' >&2
  exit 1
fi
[[ "$output" == *'[cannot_switch_to_site_owner]'* ]]
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
echo 'ok   site-owner sudo/writability failure is typed and preserves guidance'
MOCK_OWNER_WRITABLE=true

mkdir -p "$WORK/no-sudo"
if output="$(cd "$SITE_PATH" && PATH="$WORK/no-sudo" wp_run_as_site_owner datamachine memory compose AGENTS.md 2>&1)"; then
  echo 'FAIL no-sudo invocation unexpectedly composed' >&2
  exit 1
fi
[[ "$output" == *'[cannot_switch_to_site_owner]'* ]]
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
echo 'ok   missing sudo fails closed with a typed diagnostic'

MOCK_COMPOSE_FAIL=true
if output="$(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md 2>&1)"; then
  echo 'FAIL failed atomic compose unexpectedly succeeded' >&2
  exit 1
fi
[[ "$output" == *'[compose_command_failed]'* ]]
[[ "$output" != *'credential=never-display'* ]]
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
echo 'ok   compose failure is bounded, credential-free, and preserves guidance'

LOCAL_MODE=true
before_sudo="$(<"$SUDO_LOG")"
(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md)
[[ "$(<"$WP_CALL_LOG")" == *'--allow-root'* ]]
[[ "$(<"$SUDO_LOG")" = "$before_sudo" ]]
echo 'ok   local mode keeps the direct WP-CLI route'
LOCAL_MODE=false

# If a non-root invocation cannot switch to the owner, it must fail explicitly
# and leave the existing guidance intact.
export WP_CODING_AGENTS_TEST_ASSUME_ROOT=false
id() { if [ "$1" = -u ]; then printf '501\n'; else printf 'opencode\n'; fi; }
if output="$(cd "$SITE_PATH" && wp_run_as_site_owner datamachine memory compose AGENTS.md 2>&1)"; then
  echo 'FAIL non-owner invocation unexpectedly composed' >&2
  exit 1
fi
[[ "$output" == *'SITE_PATH owner'* ]]
[[ "$(<"$WORK/site/AGENTS.md")" = 'updated guidance' ]]
echo 'ok   non-owner failure is actionable and preserves AGENTS.md'
