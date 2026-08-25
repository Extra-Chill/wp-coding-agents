#!/bin/bash
set -eu
[ -z "${PLUGIN_FIXTURE_PID_FILE:-}" ] || printf '%s\n' "$$" > "$PLUGIN_FIXTURE_PID_FILE"
trap '' TERM
while :; do sleep 1; done
