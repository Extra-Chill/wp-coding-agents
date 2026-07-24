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
