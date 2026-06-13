#!/usr/bin/env bash
# tests/kimaki-managed-plugin-rig.sh — offline smoke for the Kimaki restart rig.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KIMAKI_DIST="$TMP/kimaki-dist"
ARTIFACTS="$TMP/artifacts"
mkdir -p "$KIMAKI_DIST" "$ARTIFACTS"

cat > "$KIMAKI_DIST/package.json" <<'EOF'
{"type":"module"}
EOF

cat > "$KIMAKI_DIST/store.js" <<'EOF'
let state = { critiqueEnabled: true };
export const store = {
  getState() { return state; },
  setState(next) { state = { ...state, ...next }; },
};
EOF

cat > "$KIMAKI_DIST/system-message.js" <<'EOF'
export function getOpencodeSystemMessage() {
  return `The user is reading your messages from inside Discord, via kimaki.dev

## permissions

metadata that should be stripped

## scheduled sends and task management

kimaki scheduler text that should be stripped

## running dev servers with tunnel access

ALWAYS use \`kimaki tunnel\` when starting any dev server.

## starting new sessions from CLI

You can use this to "spawn" parallel helper sessions like teammates.

kimaki send --channel 1493345787894038649 --prompt 'your prompt here' --agent <current_agent>
kimaki send --channel 1493345787894038649 --prompt 'Add dark mode support' --worktree dark-mode --agent <current_agent>
kimaki send --channel 1493345787894038649 --prompt 'Run the restricted task' --cwd /path/to/project --agent <current_agent>

## creating worktrees

kimaki send --channel 1493345787894038649 --prompt 'your task description' --worktree worktree-name --agent <current_agent>

## cross-project commands

kimaki project list --json
kimaki send --project /path/to/other-repo --prompt 'Plan how to update this checkout' --agent <current_agent>

## waiting for a session to finish

kimaki send --thread <thread_id> --prompt 'Run the tests' --wait --agent <current_agent>

## reading other sessions

cross-session discovery text that should be stripped

## markdown formatting

Keep this section.
`;
}
EOF

node "$ROOT/scripts/kimaki-managed-plugin-rig.mjs" \
  --kimaki-dist-dir "$KIMAKI_DIST" \
  --artifact-dir "$ARTIFACTS"

node - "$ARTIFACTS/manifest.json" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (manifest.schema !== 'wp-coding-agents/kimaki-managed-plugin-rig/v1') {
  throw new Error(`unexpected schema: ${manifest.schema}`);
}
if (manifest.cycles.length !== 2) {
  throw new Error(`expected 2 restart cycles, got ${manifest.cycles.length}`);
}
for (const cycle of manifest.cycles) {
  if (cycle.post_upgrade.status !== 0) {
    throw new Error(`${cycle.name} post-upgrade failed`);
  }
  const labels = cycle.checks.map((check) => check.label);
  for (const expected of [
    `${cycle.name}: raw Kimaki prompt contains tunnel section`,
    `${cycle.name}: filtered prompt removes tunnel section`,
    `${cycle.name}: raw Kimaki prompt contains stale orchestration sections`,
    `${cycle.name}: filtered prompt removes stale orchestration sections`,
    `${cycle.name}: dm-context-filter hook executed`,
    `${cycle.name}: dm-agent-sync module loads`,
  ]) {
    if (!labels.includes(expected)) {
      throw new Error(`missing check: ${expected}`);
    }
  }
}
NODE

if grep -q '^## running dev servers with tunnel access$' "$ARTIFACTS/prompts/initial-start.filtered.txt"; then
  echo "FAIL: filtered prompt leaked Kimaki tunnel section"
  exit 1
fi

if grep -Eq '^## (starting new sessions from CLI|creating worktrees|cross-project commands|waiting for a session to finish)$|kimaki send|kimaki project list|Homeboy|Data Machine Code|dev\.chubes\.net' "$ARTIFACTS/prompts/initial-start.filtered.txt"; then
  echo "FAIL: filtered prompt leaked stale Kimaki orchestration guidance"
  exit 1
fi

echo "OK: Kimaki managed-plugin rig"
