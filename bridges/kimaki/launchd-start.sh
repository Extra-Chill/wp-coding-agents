#!/bin/sh
# wp-coding-agents-owned launchd entrypoint for the managed Kimaki bridge.
# launchd has no ExecStartPre equivalent, so keep macOS parity with the
# systemd unit by running preflight cleanup here before execing Kimaki.
set -eu

if command -v pkill >/dev/null 2>&1; then
  pkill -TERM -f "opencode-ai/bin/.*serve" >/dev/null 2>&1 || true
fi

config_dir="${KIMAKI_CONFIG_DIR:-${KIMAKI_DATA_DIR:-$HOME/.kimaki}/kimaki-config}"
if [ -x "$config_dir/post-upgrade.sh" ]; then
  "$config_dir/post-upgrade.sh" || true
fi

exec "$@"
