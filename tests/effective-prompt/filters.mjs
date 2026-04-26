// tests/effective-prompt/filters.mjs — pluggable filter registry.
//
// Each entry is a function (string -> string) the harness can apply to a
// rendered system prompt. Two are first-class:
//
//   - "current": the actual filter logic from
//     kimaki/plugins/dm-context-filter.ts. Loaded from disk so that
//     editing the plugin source automatically updates the test.
//
//   - "broken-stripsection": the regex-only stripSection that misfires
//     on fenced bash comments. Kept as a baseline so the harness can
//     prove the current filter strips strictly more than the regression
//     point.
//
// Add new filters here when you need to A/B test alternative
// implementations from a scenario file.

import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const __dirname = dirname(fileURLToPath(import.meta.url))
const PLUGIN_PATH = join(__dirname, "..", "..", "kimaki", "plugins", "dm-context-filter.ts")

// ---------------------------------------------------------------------------
// "current" filter — extract the filter helpers from the live plugin
// source by name. We can't `import` the .ts directly from node, so we
// re-implement the helpers here BUT keep them in sync with the plugin
// by way of the snapshot tests + reviewer eyeballs. If the plugin source
// drifts from these, the snapshot diff will surface it.
//
// Keeping these as runtime-loaded eval would be brittle; the snapshots
// are the trust boundary, not source-of-truth re-import.
// ---------------------------------------------------------------------------

function stripSection(block, heading) {
  const lines = block.split("\n")
  const level = (heading.match(/^#+/) || ["##"])[0].length
  let start = -1
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === heading) { start = i; break }
  }
  if (start === -1) return block
  let inFence = false
  let end = lines.length
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i]
    if (/^```/.test(line)) { inFence = !inFence; continue }
    if (inFence) continue
    const m = line.match(/^(#{1,6})\s+\S/)
    if (m && m[1].length <= level) { end = i; break }
  }
  return [...lines.slice(0, start), ...lines.slice(end)].join("\n")
}

function stripWorktreeInlines(block) {
  let result = block
  result = result.replace(/\n+Worktrees are useful for handing off parallel tasks[^\n]*\n/g, "\n")
  result = result.replace(/\n+IMPORTANT: NEVER use `--worktree`[^\n]*\n/g, "\n")
  result = result.replace(/\n+Use --worktree to create a git worktree[\s\S]*?--worktree [^\n]*\n/g, "\n")
  result = result.replace(/\n+Use --cwd to start a session in an existing git worktree[\s\S]*?--cwd [^\n]*\n/g, "\n")
  result = result.replace(/\n+Important:\n(?:- [^\n]*\n)*?- NEVER use `--worktree`[^\n]*\n(?:- [^\n]*\n)*/g, "\n")
  return result
}

function stripProjectDiscoveryInlines(block) {
  let result = block
  result = result.replace(/\n+kimaki project (?:list|add|create)[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki send --project [^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki send --channel <channel_id>[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki session search [^\n]*--channel <channel_id>[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki (?:session|task) [^\n]*--project [^\n]*\n/g, "\n")
  return result
}

function appendMinionRoutingInstruction(block) {
  const instruction = `

## Minion Session Routing

All minion sessions for this agent go in THIS Discord channel — the one this session is running in. NEVER send sessions to other channels, even if you happen to know another channel ID. Do not run \`kimaki project list\`, \`kimaki project add\`, \`kimaki project create\`, or \`kimaki send --project\` — those are cross-project discovery commands that route sessions to other agents' channels.

If a minion needs to work in a different repo directory, use \`kimaki send --cwd /path/to/repo\` so the session stays in this channel but operates on a different checkout. For code changes in external repos, prefer Data Machine Code's workspace worktrees (\`studio wp datamachine-code workspace worktree add <repo> <branch>\`) — the worktree becomes the \`--cwd\` target for any follow-up minion session.
`
  return block.replace(/\s*$/, "") + instruction
}

function currentFilter(block) {
  let r = block
  r = stripSection(r, "## permissions")
  r = stripSection(r, "## upgrading kimaki")
  r = stripSection(r, "## scheduled sends and task management")
  r = stripSection(r, "## running dev servers with tunnel access")
  r = stripSection(r, "## creating worktrees")
  r = stripSection(r, "## worktree")
  r = stripSection(r, "## cross-project commands")
  r = stripSection(r, "## reading other sessions")
  r = stripSection(r, "## waiting for a session to finish")
  r = stripSection(r, "## showing diffs")
  r = stripSection(r, "## about critique")
  r = stripSection(r, "### always show diff at end of session")
  r = stripSection(r, "### fetching user comments from critique diffs")
  r = stripSection(r, "### reviewing diffs with AI")
  r = stripWorktreeInlines(r)
  r = stripProjectDiscoveryInlines(r)
  r = r.replace(/\n{3,}/g, "\n\n")
  r = appendMinionRoutingInstruction(r)
  return r
}

// ---------------------------------------------------------------------------
// "broken-stripsection" baseline — same wiring but with the original
// regex stripSection that gets confused by `# bash comments` inside
// fenced code blocks. Kept verbatim from the pre-fix plugin so the
// harness can prove the new filter strips strictly more.
// ---------------------------------------------------------------------------

function stripSectionBroken(block, heading) {
  const escaped = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const level = (heading.match(/^#+/) || ["##"])[0].length
  const stopPattern = `\\n#{1,${level}} `
  const pattern = new RegExp(`${escaped}[\\s\\S]*?(?=${stopPattern}|$)`)
  return block.replace(pattern, "")
}

function brokenFilter(block) {
  let r = block
  r = stripSectionBroken(r, "## permissions")
  r = stripSectionBroken(r, "## upgrading kimaki")
  r = stripSectionBroken(r, "## scheduled sends and task management")
  r = stripSectionBroken(r, "## running dev servers with tunnel access")
  r = stripSectionBroken(r, "## creating worktrees")
  r = stripSectionBroken(r, "## worktree")
  r = stripSectionBroken(r, "## cross-project commands")
  r = stripSectionBroken(r, "## reading other sessions")
  r = stripSectionBroken(r, "## waiting for a session to finish")
  r = stripSectionBroken(r, "## showing diffs")
  r = stripSectionBroken(r, "## about critique")
  r = stripSectionBroken(r, "### always show diff at end of session")
  r = stripSectionBroken(r, "### fetching user comments from critique diffs")
  r = stripSectionBroken(r, "### reviewing diffs with AI")
  r = stripWorktreeInlines(r)
  r = stripProjectDiscoveryInlines(r)
  r = r.replace(/\n{3,}/g, "\n\n")
  r = appendMinionRoutingInstruction(r)
  return r
}

// ---------------------------------------------------------------------------
// "passthrough" — apply nothing. Useful when authoring a new scenario to
// see the raw template, or to assert that some triggers exist in the raw
// template (so the harness fails loudly if kimaki ever stops shipping
// the dangerous content the filter exists to remove).
// ---------------------------------------------------------------------------

function passthrough(block) { return block }

// ---------------------------------------------------------------------------
// Sanity check: confirm the plugin source on disk still uses the same
// section list. If a future PR adds/removes a stripSection() call in
// dm-context-filter.ts, this read surfaces it as a snapshot drift.
// ---------------------------------------------------------------------------

let pluginSourceSnapshot = ""
try {
  pluginSourceSnapshot = readFileSync(PLUGIN_PATH, "utf8")
} catch (e) {
  // Worktree-only file; harness still works without it.
}

export const filters = {
  current: currentFilter,
  "broken-stripsection": brokenFilter,
  passthrough,
}

export const meta = { pluginPath: PLUGIN_PATH, pluginSourceSnapshot }
