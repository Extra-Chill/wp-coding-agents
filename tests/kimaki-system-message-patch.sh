#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/config/plugins" "$TMP/config/skills" "$TMP/live-skills" "$TMP/dist"
touch "$TMP/config/plugins/dm-context-filter.ts" "$TMP/config/plugins/dm-agent-sync.ts"
printf '%s\n' '{"type":"module"}' > "$TMP/dist/package.json"

for parameters in \
  'sessionId, channelId, guildId, threadId, channelTopic, agents, userId,' \
  'sessionId, channelId, guildId, threadId, channelTopic, agents, userId, parentSessionId,'
do
  cat > "$TMP/dist/system-message.js" <<EOF
export function getOpencodeSystemMessage({ $parameters }) {
    return 'original';
}
EOF

  KIMAKI_DIST_DIR="$TMP/dist" \
  KIMAKI_SKILLS_DIR="$TMP/live-skills" \
  KIMAKI_SKILL_SOURCE_DIR="$TMP/config/skills" \
  KIMAKI_PLUGIN_SOURCE_DIR="$TMP/config/plugins" \
    "$ROOT/bridges/kimaki/post-upgrade.sh" >/dev/null

  if ! grep -qF 'wp-coding-agents managed Kimaki system prompt patch' "$TMP/dist/system-message.js"; then
    echo "FAIL: system prompt patch did not support parameters: $parameters"
    exit 1
  fi

  node --input-type=module - "$TMP/dist/system-message.js" <<'NODE'
import { pathToFileURL } from 'node:url'

const modulePath = process.argv[2]
const { getOpencodeSystemMessage } = await import(pathToFileURL(modulePath).href)
const prompt = getOpencodeSystemMessage({})
if (!prompt.includes('$HOME/.kimaki/kimaki.log') || prompt.includes('\\$HOME/.kimaki/kimaki.log')) {
  throw new Error('managed system prompt must include the literal Kimaki log path')
}
NODE
done

echo "PASS: Kimaki system prompt patch supports known signatures"

# ----------------------------------------------------------------------------
# A failing prompt patch must never abort the script.
#
# post-upgrade.sh runs with `set -e` as ExecStartPre with no `-` prefix on the
# unit directive, so any non-zero exit inside it stops the service from starting
# at all. The prompt patch mutates the root-owned npm package directory, which a
# non-root SERVICE_USER cannot write — a root `npm install -g kimaki` followed by
# a restart took an install down for five days over ~29,900 attempts.
#
# These pin the rule Passes 1 and 3 already follow: failing to mutate the package
# directory is a warning, never a failed start.
# ----------------------------------------------------------------------------

run_post_upgrade() {
  KIMAKI_DIST_DIR="$TMP/dist" \
  KIMAKI_SKILLS_DIR="$TMP/live-skills" \
  KIMAKI_SKILL_SOURCE_DIR="$TMP/config/skills" \
  KIMAKI_PLUGIN_SOURCE_DIR="$TMP/config/plugins" \
    "$ROOT/bridges/kimaki/post-upgrade.sh" 2>&1
}

# Case 1: the patch cannot find its target signature (node exits non-zero).
# Deliberately not a permissions test, so it is deterministic for every caller
# including root.
cat > "$TMP/dist/system-message.js" <<'EOF'
export function someUnrelatedExport() {
    return 'original';
}
EOF

status=0
output="$(run_post_upgrade)" || status=$?

if [[ "$status" -ne 0 ]]; then
  echo "FAIL: post-upgrade.sh exited $status when the prompt patch failed; ExecStartPre must not block service start"
  printf '%s\n' "$output"
  exit 1
fi

if ! grep -qF 'kimaki-config: done' <<<"$output"; then
  echo "FAIL: post-upgrade.sh aborted before its closing summary when the prompt patch failed"
  printf '%s\n' "$output"
  exit 1
fi

if ! grep -qF 'prompt patch failed' <<<"$output"; then
  echo "FAIL: a failed prompt patch must be reported in the summary"
  printf '%s\n' "$output"
  exit 1
fi

echo "PASS: a failed Kimaki system prompt patch warns without blocking service start"

# Case 2: the exact outage shape — the target exists but is not writable by the
# invoking user. Root bypasses file permissions, so this can only be observed as
# a non-root caller.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: unwritable-target case requires a non-root caller"
else
  cat > "$TMP/dist/system-message.js" <<'EOF'
export function getOpencodeSystemMessage({ sessionId, channelId }) {
    return 'original';
}
EOF
  chmod 0444 "$TMP/dist/system-message.js"

  status=0
  output="$(run_post_upgrade)" || status=$?
  chmod 0644 "$TMP/dist/system-message.js"

  if [[ "$status" -ne 0 ]]; then
    echo "FAIL: post-upgrade.sh exited $status against an unwritable system-message.js; this is the five-day outage"
    printf '%s\n' "$output"
    exit 1
  fi

  if ! grep -qF 'cannot write' <<<"$output"; then
    echo "FAIL: an unwritable system-message.js must be reported by name"
    printf '%s\n' "$output"
    exit 1
  fi

  if ! grep -qF 'prompt patch unwritable' <<<"$output"; then
    echo "FAIL: an unwritable target must be distinguished from a failed patch in the summary"
    printf '%s\n' "$output"
    exit 1
  fi

  echo "PASS: an unwritable Kimaki system-message.js warns without blocking service start"
fi
