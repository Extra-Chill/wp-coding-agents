#!/bin/sh
# Invocation-scoped Kimaki -> Homeboy notification context.
#
# This runs inside the OpenCode shell tool subprocess, where upstream Kimaki
# may export attribution for this invocation. Do not move this mapping into the
# OpenCode server process: it can host concurrent Discord sessions.
set -eu

snowflake_re='^[0-9][0-9]*$'
route=''

if [ -n "${KIMAKI_THREAD_ID:-}" ] && printf '%s' "$KIMAKI_THREAD_ID" | grep -Eq "$snowflake_re" && [ "${#KIMAKI_THREAD_ID}" -ge 17 ] && [ "${#KIMAKI_THREAD_ID}" -le 20 ]; then
  route="discord:v1:thread:$KIMAKI_THREAD_ID"
elif [ -n "${KIMAKI_CHANNEL_ID:-}" ] && printf '%s' "$KIMAKI_CHANNEL_ID" | grep -Eq "$snowflake_re" && [ "${#KIMAKI_CHANNEL_ID}" -ge 17 ] && [ "${#KIMAKI_CHANNEL_ID}" -le 20 ]; then
  route="discord:v1:channel:$KIMAKI_CHANNEL_ID"
fi

if [ -n "$route" ]; then
  export HOMEBOY_NOTIFICATION_TRANSPORT='discord.run-completion'
  export HOMEBOY_NOTIFICATION_ROUTE="$route"
else
  unset HOMEBOY_NOTIFICATION_TRANSPORT HOMEBOY_NOTIFICATION_ROUTE
fi

exec homeboy "$@"
