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
  printf '%s\0' "$@" > "$TMP/cli-channel.$1.args"
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
  python3 - "$TMP/cli-channel.${1:-roadie}.args" "${2:-name}" <<'PY'
import sys
with open(sys.argv[1], 'rb') as handle:
    parts = [p.decode() for p in handle.read().split(b'\0') if p]
index = {"name": 0, "command": 1, "args": 2, "timeout": 3, "env": 4}[sys.argv[2]]
print(parts[index] if len(parts) > index else '')
PY
}

env_value() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$(registered "$2" env)" "$1"
}

echo "==> VPS install registers the system-prefix binary with send-token env"
rm -f "$TMP/cli-channel."*.args
LOCAL_MODE=false SERVICE_USER=pi SERVICE_HOME=/home/pi \
  ROADIE_DATA_DIR=/home/pi/.roadie ROADIE_LOCK_PORT=29988 \
  ROADIE_SYSTEM_PREFIX=/usr/local/lib/wp-coding-agents/roadie \
  ROADIE_SECRETS_ROOT=/etc/wp-coding-agents \
  _roadie_register_cli_channel

[ "$(registered roadie name)" = roadie ] && ok "channel name is roadie" || fail "channel name: '$(registered roadie name)'"
got="$(registered roadie command)"
[ "$got" = /usr/local/lib/wp-coding-agents/roadie/bin/roadie ] \
  && ok "registers the system-prefix binary" || fail "expected system-prefix binary, got '$got'"
case "$got" in
  /root/*|/home/*) fail "registered command is under a private home: $got" ;;
  *) ok "registered command is outside private homes" ;;
esac
[ "$(registered roadie args)" = '["send","--channel","{recipient}","--prompt","{message}"]' ] \
  && ok "send argv" || fail "argv: $(registered roadie args)"
[ "$(registered roadie-notify name)" = roadie-notify ] && ok "notify channel name" || fail "notify channel name: '$(registered roadie-notify name)'"
[ "$(registered roadie-notify command)" = "$got" ] && ok "notify uses same binary" || fail "notify command: '$(registered roadie-notify command)'"
[ "$(registered roadie-notify args)" = '["send","--channel","{recipient}","--prompt","{message}","--notify-only"]' ] \
  && ok "notify-only argv" || fail "notify argv: $(registered roadie-notify args)"
[ "$(registered roadie-notify timeout)" = "$(registered roadie timeout)" ] && ok "notify uses same timeout" || fail "notify timeout differs"
[ "$(registered roadie-notify env)" = "$(registered roadie env)" ] && ok "notify uses same env" || fail "notify env differs"
[ "$(env_value ROADIE_SERVICE_TOKEN_FILE roadie)" = /etc/wp-coding-agents/roadie/send-token ] \
  && ok "send token file passed" || fail "token file: '$(env_value ROADIE_SERVICE_TOKEN_FILE roadie)'"
[ "$(env_value ROADIE_DATA_DIR roadie)" = /home/pi/.roadie ] \
  && ok "service data dir passed (unreadable to the web user, so send goes remote)" \
  || fail "data dir: '$(env_value ROADIE_DATA_DIR roadie)'"
[ "$(env_value ROADIE_LOCK_PORT roadie)" = 29988 ] && ok "lock port passed" || fail "lock port: '$(env_value ROADIE_LOCK_PORT roadie)'"

echo "==> VPS install without an explicit lock port pins the default port for the service's own data dir"
# The bot (HOME=/home/pi) treats ~/.roadie as its default data dir and
# serves port 29988. The web-user caller runs with HOME=/tmp, so without a
# pinned port it would hash the data dir path to a port nobody listens on.
rm -f "$TMP/cli-channel."*.args
(
  unset ROADIE_LOCK_PORT
  LOCAL_MODE=false SERVICE_USER=pi SERVICE_HOME=/home/pi \
    ROADIE_DATA_DIR=/home/pi/.roadie \
    ROADIE_SYSTEM_PREFIX=/usr/local/lib/wp-coding-agents/roadie \
    ROADIE_SECRETS_ROOT=/etc/wp-coding-agents \
    _roadie_register_cli_channel
)
[ "$(env_value ROADIE_LOCK_PORT roadie)" = 29988 ] \
  && ok "default data dir pins the default lock port" \
  || fail "default data dir lock port: '$(env_value ROADIE_LOCK_PORT roadie)'"
[ "$(env_value ROADIE_LOCK_PORT roadie-notify)" = 29988 ] \
  && ok "notify channel pins the default lock port" \
  || fail "notify lock port: '$(env_value ROADIE_LOCK_PORT roadie-notify)'"

echo "==> custom data dir without an explicit lock port leaves the port to Roadie's path hash"
rm -f "$TMP/cli-channel."*.args
(
  unset ROADIE_LOCK_PORT
  LOCAL_MODE=false SERVICE_USER=pi SERVICE_HOME=/home/pi \
    ROADIE_DATA_DIR=/home/pi/.roadie-site-b \
    ROADIE_SYSTEM_PREFIX=/usr/local/lib/wp-coding-agents/roadie \
    ROADIE_SECRETS_ROOT=/etc/wp-coding-agents \
    _roadie_register_cli_channel
)
[ -z "$(env_value ROADIE_LOCK_PORT roadie)" ] \
  && ok "custom data dir does not pin a port" \
  || fail "custom data dir pinned: '$(env_value ROADIE_LOCK_PORT roadie)'"

echo "==> local install registers the PATH binary"
rm -f "$TMP/cli-channel."*.args
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/roadie"
chmod 0755 "$TMP/bin/roadie"
LOCAL_MODE=true ROADIE_DATA_DIR="$TMP/.roadie" PATH="$TMP/bin:/usr/bin:/bin" _roadie_register_cli_channel
[ "$(registered roadie command)" = "$TMP/bin/roadie" ] && ok "local PATH binary" || fail "local command: '$(registered roadie command)'"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
echo "OK: all cli-channel assertions passed"
