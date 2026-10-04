#!/usr/bin/env bash
# tests/cli-channel-binary-path.sh — the Roadie CLI channel is reachable by the
# web user (issue #198).
#
# The `roadie` CLI channel is shelled by the wp-coding-agents CLI transport from
# `agents/dispatch-message`, inside PHP-FPM as the web user (www-data). That
# user is not the Roadie service user and cannot open the Roadie data dir.
#
# Roadie covers this without a sudo hop: the package lives in a root-owned,
# world-readable system prefix, and `roadie send` posts to the running bot
# with a send token when it cannot open the data dir. So the channel must:
#   1. register the system-prefix binary on VPS installs, never a binary
#      under a private home;
#   2. pass ROADIE_SERVICE_TOKEN_FILE, the service's ROADIE_DATA_DIR and
#      ROADIE_LOCK_PORT so `roadie send` takes the remote path to the right
#      bot;
#   3. use `send --channel {recipient} --prompt {message}`;
#   4. register the PATH binary on local installs (same user, no prefix).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/wpca-cli-channel.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

log() { :; }
warn() { printf 'WARN: %s\n' "$1" >&2; }
cli_channel_register() {
  printf '%s\0' "$@" > "$TMP/cli-channel.args"
}

DRY_RUN=false
UPDATED_ITEMS=()

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/bridges/roadie.sh"

FAILED=0
fail() { echo "  FAIL $1"; FAILED=$((FAILED + 1)); }
ok()   { echo "  ok   $1"; }

# Print one registered argument: name, command, args, timeout, env.
registered() {
  python3 - "$TMP/cli-channel.args" "$1" <<'PY'
import sys
with open(sys.argv[1], 'rb') as handle:
    parts = [p.decode() for p in handle.read().split(b'\0') if p]
index = {"name": 0, "command": 1, "args": 2, "timeout": 3, "env": 4}[sys.argv[2]]
print(parts[index] if len(parts) > index else '')
PY
}

env_value() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$(registered env)" "$1"
}

echo "==> VPS install registers the system-prefix binary with send-token env"
rm -f "$TMP/cli-channel.args"
LOCAL_MODE=false SERVICE_USER=opencode SERVICE_HOME=/home/opencode \
  ROADIE_DATA_DIR=/home/opencode/.roadie ROADIE_LOCK_PORT=29988 \
  ROADIE_SYSTEM_PREFIX=/usr/local/lib/wp-coding-agents/roadie \
  ROADIE_SECRETS_ROOT=/etc/wp-coding-agents \
  _roadie_register_cli_channel

[ "$(registered name)" = roadie ] && ok "channel name is roadie" || fail "channel name: '$(registered name)'"
got="$(registered command)"
[ "$got" = /usr/local/lib/wp-coding-agents/roadie/bin/roadie ] \
  && ok "registers the system-prefix binary" || fail "expected system-prefix binary, got '$got'"
case "$got" in
  /root/*|/home/*) fail "registered command is under a private home: $got" ;;
  *) ok "registered command is outside private homes" ;;
esac
[ "$(registered args)" = '["send","--channel","{recipient}","--prompt","{message}"]' ] \
  && ok "send argv" || fail "argv: $(registered args)"
[ "$(env_value ROADIE_SERVICE_TOKEN_FILE)" = /etc/wp-coding-agents/roadie/send-token ] \
  && ok "send token file passed" || fail "token file: '$(env_value ROADIE_SERVICE_TOKEN_FILE)'"
[ "$(env_value ROADIE_DATA_DIR)" = /home/opencode/.roadie ] \
  && ok "service data dir passed (unreadable to the web user, so send goes remote)" \
  || fail "data dir: '$(env_value ROADIE_DATA_DIR)'"
[ "$(env_value ROADIE_LOCK_PORT)" = 29988 ] && ok "lock port passed" || fail "lock port: '$(env_value ROADIE_LOCK_PORT)'"

echo "==> local install registers the PATH binary"
rm -f "$TMP/cli-channel.args"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/roadie"
chmod 0755 "$TMP/bin/roadie"
LOCAL_MODE=true ROADIE_DATA_DIR="$TMP/.roadie" PATH="$TMP/bin:/usr/bin:/bin" _roadie_register_cli_channel
[ "$(registered command)" = "$TMP/bin/roadie" ] && ok "local PATH binary" || fail "local command: '$(registered command)'"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all cli-channel assertions passed"
