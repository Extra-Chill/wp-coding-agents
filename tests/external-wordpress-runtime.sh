#!/bin/bash
# Pi-only external WordPress transport and projected context contract.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/wordpress.sh"
source "$SCRIPT_DIR/lib/external-wordpress.sh"
source "$SCRIPT_DIR/lib/ai-gateway.sh"
log() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; return 1; }
DRY_RUN=false
LOCAL_MODE=true
EXTERNAL_WORDPRESS=true
RUNTIME_PROJECT_ROOT="$TMP/project"
SITE_PATH="$RUNTIME_PROJECT_ROOT"
WORDPRESS_PATH='/remote/site root'
WORDPRESS_USER='agent user'
UPDATED_ITEMS=()
mkdir -p "$RUNTIME_PROJECT_ROOT" "$TMP/bin"
cat > "$TMP/bin/wp" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >> "$WP_TEST_ARGS"
case "$*" in
  *'core is-installed'*) exit 0 ;;
  *'option get siteurl'*) echo https://example.test ;;
  *'datamachine agent paths'*) echo '{}' ;;
esac
SH
chmod +x "$TMP/bin/wp"
export WP_TEST_ARGS="$TMP/args"
export WP_CONTROL_TRANSPORT_JSON="[\"$TMP/bin/wp\",\"secret value with spaces\"]"
external_wordpress_prepare_transport
external_wordpress_validate
"$RUNTIME_PROJECT_ROOT/.wp-coding-agents/bin/wp-control" core is-installed
# Runtime launchers preserve path/user without writing transport credentials.
grep -Fx -- '--path=/remote/site root' "$WP_TEST_ARGS"
grep -Fx -- '--user=agent user' "$WP_TEST_ARGS"
grep -Fx -- 'secret value with spaces' "$WP_TEST_ARGS"
! grep -R -F 'secret value with spaces' "$RUNTIME_PROJECT_ROOT"
# Gateway credentials on external hosts remain environment-only.
WITH_AI_GATEWAY=true
OPENAI_BASE_URL=https://runtime.invalid/private
OPENAI_API_KEY=runtime-secret
ai_gateway_write_env
[ ! -e "$RUNTIME_PROJECT_ROOT/.wp-coding-agents/wp-ai-gateway.env" ]
[ ! -e "$RUNTIME_PROJECT_ROOT/opencode.json" ]
[ ! -e "$RUNTIME_PROJECT_ROOT/wp-content" ]
WP_CONTROL_TRANSPORT_JSON='["/does/not/exist"]'
external_wordpress_prepare_transport
if external_wordpress_validate; then
  echo 'FAIL: unavailable transport validated'; exit 1
fi
echo 'PASS: external WordPress Pi-only transport'
