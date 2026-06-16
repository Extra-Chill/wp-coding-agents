#!/usr/bin/env bash
# tests/kimaki-managed-plugin-rig.sh — offline smoke for the Kimaki restart rig.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KIMAKI_DIST="$TMP/kimaki-dist"
ARTIFACTS="$TMP/artifacts"
mkdir -p "$KIMAKI_DIST" "$ARTIFACTS"

node "$ROOT/scripts/kimaki-managed-plugin-rig.mjs" --self-test-args

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

## uploading files to discord

kimaki upload-to-discord --session ses_example artifact.txt

## requesting files from the user

Use the native file picker.

## archiving the current thread

kimaki session archive --session ses_example

## generating audio from text

kimaki tts 'summary' -o /tmp/summary.mp3

## showing diffs

Always run bunx critique --web and upload diffs to critique.work.

## about critique

critique is an external diff viewer that must not leak into managed context.

<available_skills>
  <skill>
    <name>critique</name>
    <description>Diff viewer skill that must not leak into managed context.</description>
  </skill>
  <skill>
    <name>playwriter</name>
    <description>Browser automation skill that must not leak unless explicitly allowlisted.</description>
  </skill>
</available_skills>

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
    `${cycle.name}: raw Kimaki prompt is generic or already managed`,
    `${cycle.name}: filtered prompt removes tunnel section`,
    `${cycle.name}: raw Kimaki prompt contains stale orchestration sections or is already managed`,
    `${cycle.name}: filtered prompt removes stale orchestration sections`,
    `${cycle.name}: bundled critique skill removed from npm skills dir`,
    `${cycle.name}: package-local upgrade skill duplicate removed`,
    `${cycle.name}: persistent upgrade skill source remains present`,
    `${cycle.name}: generated skill permission denies unlisted skills`,
    `${cycle.name}: generated skill permission allows upgrade skill`,
    `${cycle.name}: dm-context-filter hook executed`,
    `${cycle.name}: final system transform preserves trailing instruction blocks`,
    `${cycle.name}: system and message transforms agree`,
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

if grep -Eiq '^## (showing diffs|about critique|uploading files to discord|requesting files from the user|archiving the current thread|generating audio from text)$|\bkimaki (send|session|project|tunnel|upload-to-discord|tts|task)\b|<available_skills>|<skill>|</skill>|<name>(critique|playwriter)</name>|critique\.work|\b(bunx )?critique\b' "$ARTIFACTS/prompts/initial-start.filtered.txt"; then
  echo "FAIL: filtered prompt leaked generic Kimaki guidance or non-allowlisted skills"
  exit 1
fi

echo "OK: Kimaki managed-plugin rig"
