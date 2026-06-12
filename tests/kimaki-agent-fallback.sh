#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/wp-coding-agents-kimaki-agent-fallback.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# mktemp -d creates the dir at 0700. The CLI-channel resolver now refuses to
# register a binary whose ancestor dirs are not world-traversable (the #198
# fix: a /root- or /home/opencode-trapped binary is unreachable by the
# www-data CLI-dispatch transport). These fixtures simulate normally-installed,
# web-reachable binaries, so make the temp root 0755 to match that reality.
chmod 0755 "$TMP"

if [ -e "$ROOT/bridges/kimaki/bin/datamachine-kimaki" ]; then
  echo "FAIL: datamachine-kimaki adapter should not be shipped"
  exit 1
fi

if grep -R "stripAgentOverrideInlines" "$ROOT/bridges/kimaki/plugins" >/dev/null; then
  echo "FAIL: dm-context-filter still strips generic Kimaki agent guidance"
  exit 1
fi

if grep -R "normalize.*Kimaki send\|normalise.*Kimaki send\|--agent build\|DATAMACHINE_REAL_KIMAKI" \
  "$ROOT/bridges" "$ROOT/README.md" "$ROOT/docs" >/dev/null; then
  echo "FAIL: stale Kimaki agent-normalization compensation remains"
  exit 1
fi

cli_channel_register() {
  printf '%s\0' "$@" > "$TMP/cli-channel.args"
}

log() { :; }
warn() { printf 'WARN: %s\n' "$1" >&2; }

DRY_RUN=false
UPDATED_ITEMS=()
KIMAKI_BIN="$TMP/native-kimaki"
touch "$KIMAKI_BIN"
chmod +x "$KIMAKI_BIN"

# shellcheck disable=SC1091
source "$ROOT/bridges/kimaki.sh"

_kimaki_register_cli_channel
python3 - "$TMP/cli-channel.args" "$KIMAKI_BIN" <<'PY'
import sys
path, kimaki_bin = sys.argv[1:]
with open(path, 'rb') as handle:
    actual = [part.decode() for part in handle.read().split(b'\0') if part]
expected = [
    'kimaki',
    kimaki_bin,
    '["send","--channel","{recipient}","--prompt","{message}"]',
    'true',
    '600',
]
if actual != expected:
    raise SystemExit(f'expected {expected!r}, got {actual!r}')
PY

legacy_first_dir="$TMP/legacy-first"
native_second_dir="$TMP/native-second"
mkdir -p "$legacy_first_dir" "$native_second_dir"
printf '%s\n' '# wp-coding-agents datamachine-kimaki adapter' > "$legacy_first_dir/kimaki"
cp "$KIMAKI_BIN" "$native_second_dir/kimaki"
chmod +x "$legacy_first_dir/kimaki" "$native_second_dir/kimaki"
KIMAKI_BIN="$legacy_first_dir/kimaki"
PATH="$legacy_first_dir:$native_second_dir:$PATH" _kimaki_register_cli_channel
python3 - "$TMP/cli-channel.args" "$native_second_dir/kimaki" <<'PY'
import sys
path, kimaki_bin = sys.argv[1:]
with open(path, 'rb') as handle:
    actual = [part.decode() for part in handle.read().split(b'\0') if part]
if actual[1] != kimaki_bin:
    raise SystemExit(f'expected native kimaki {kimaki_bin!r}, got {actual[1]!r}')
PY

legacy_dir="$TMP/bin"
mkdir -p "$legacy_dir"
printf '%s\n' '# wp-coding-agents datamachine-kimaki adapter' > "$legacy_dir/datamachine-kimaki"
printf '%s\n' '# wp-coding-agents datamachine-kimaki adapter' > "$legacy_dir/kimaki"
_kimaki_remove_legacy_command_shims "$legacy_dir"
if [ -e "$legacy_dir/datamachine-kimaki" ] || [ -e "$legacy_dir/kimaki" ]; then
  echo "FAIL: legacy wp-coding-agents Kimaki adapter files were not removed"
  exit 1
fi

node <<'NODE'
function resolveValidatedAgentPreference(agentPreference, availableAgents) {
  if (!agentPreference) return undefined
  const hasAgent = availableAgents.some((agent) => agent.name === agentPreference)
  return hasAgent ? agentPreference : undefined
}

const agents = [{ name: 'build' }, { name: 'plan' }]
if (resolveValidatedAgentPreference('plan', agents) !== 'plan') {
  throw new Error('known Kimaki agent should be preserved')
}
if (resolveValidatedAgentPreference('opencode', agents) !== undefined) {
  throw new Error('unknown Kimaki agent should fall back to default/build')
}
NODE

echo "OK: Kimaki native fallback replaces local agent normalization"
