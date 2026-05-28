// tests/effective-prompt/filters.mjs — pluggable filter registry.
//
// Each entry is a function (string -> string) the harness can apply to a
// rendered system prompt. Two are first-class:
//
//   - "current": the actual dm-context-filter.ts OpenCode plugin hook.
//     Loaded from disk so that editing the plugin source automatically
//     updates the test.
//
//   - "broken-stripsection": the regex-only stripSection that misfires
//     on fenced bash comments. Kept as a baseline so the harness can
//     prove the current filter strips strictly more than the regression
//     point.
//
// Add new filters here when you need to A/B test alternative
// implementations from a scenario file.

import { dirname, join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const __dirname = dirname(fileURLToPath(import.meta.url))
const PLUGIN_PATH = join(__dirname, "..", "..", "bridges", "kimaki", "plugins", "dm-context-filter.ts")

// ---------------------------------------------------------------------------
// Baseline helper copies — intentionally kept only for the broken baseline.
// The "current" filter below imports and executes the real OpenCode plugin.
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
  result = result.replace(/\n+When the user references another project by name,[\s\S]*?root project directories\.\n/g, "\n")
  result = result.replace(/\n+When the user uses `#project-name` syntax,[\s\S]*?before acting,[^\n]*\n/g, "\n")
  result = result.replace(/\n+To send a task to another project:[\s\S]*?(?=\n\S|$)/g, "\n")
  result = result.replace(/\n+When sending prompts to other projects,[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki project (?:list|add|create)[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki send --project [^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki send --channel <channel_id>[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki session search [^\n]*--channel <channel_id>[^\n]*\n/g, "\n")
  result = result.replace(/\n+kimaki (?:session|task) [^\n]*--project [^\n]*\n/g, "\n")
  result = result.replace(/\n+[^\n]*(?:project channel|cross-project|#project-name|other project|another project)[^\n]*\n/gi, "\n")
  return result
}

function appendDataMachineSessionHandoffInstruction(block) {
  const instruction = `

## Data Machine Session Handoff

For parallel repo work, create or reuse a Data Machine Code workspace checkout, then launch the helper session through the Kimaki bridge helper. Data Machine Code owns repo/workspace setup; Kimaki carries the Discord session.

Typical flow:

1. Create the checkout with \`studio wp datamachine-code workspace worktree add <repo> <branch>\`.
2. Start the helper session with \`datamachine-kimaki-session --channel <current_channel> --cwd <workspace_path> --prompt '<task>'\`.
3. Use the helper thread for the isolated task and bring the result back here.
`
  return block.replace(/\s*$/, "") + instruction
}

function appendWordPressSiteRuntimeInstruction(block) {
  const instruction = `

## WordPress Site Runtime

This is a Data Machine-managed WordPress agent install. Use the existing WordPress site runtime by default — do not start a separate dev server just to work on the site.

On local WordPress Studio installs, use Studio and \`studio wp\` against the existing site. On VPS installs, use the live WordPress site and \`wp\` in the configured site path.

Use \`kimaki tunnel\` only when the task specifically needs an inbound public URL, such as GitHub webhooks, OAuth callbacks, or an explicit browser preview for someone who cannot access the local/VPS site directly.
`
  return block.replace(/\s*$/, "") + instruction
}

async function currentFilter(block) {
  const pluginModule = await import(pathToFileURL(PLUGIN_PATH).href)
  const plugin = await pluginModule.default({})
  const transform = plugin["experimental.chat.system.transform"]
  if (typeof transform !== "function") {
    throw new Error(`dm-context-filter plugin is missing experimental.chat.system.transform: ${PLUGIN_PATH}`)
  }

  const output = { system: [block] }
  await transform({}, output)
  return output.system.join("\n")
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
  r = stripSectionBroken(r, "## starting new sessions from CLI")
  r = stripSectionBroken(r, "## creating worktrees")
  r = stripSectionBroken(r, "## worktree")
  r = stripSectionBroken(r, "## cross-project commands")
  r = stripSectionBroken(r, "## reading other sessions")
  r = stripSectionBroken(r, "## waiting for a session to finish")
  r = stripSectionBroken(r, "## running opencode commands via kimaki send")
  r = stripSectionBroken(r, "## switching agents in the current session")
  r = stripSectionBroken(r, "## showing diffs")
  r = stripSectionBroken(r, "## about critique")
  r = stripSectionBroken(r, "### always show diff at end of session")
  r = stripSectionBroken(r, "### fetching user comments from critique diffs")
  r = stripSectionBroken(r, "### reviewing diffs with AI")
  r = stripWorktreeInlines(r)
  r = stripProjectDiscoveryInlines(r)
  r = r.replace(/\n{3,}/g, "\n\n")
  r = appendWordPressSiteRuntimeInstruction(r)
  r = appendDataMachineSessionHandoffInstruction(r)
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
export const filters = {
  current: currentFilter,
  "broken-stripsection": brokenFilter,
  passthrough,
}

export const meta = { pluginPath: PLUGIN_PATH }
