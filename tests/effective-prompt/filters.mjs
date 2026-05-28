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

function stripAgentOverrideInlines(block) {
  let result = block
  result = result.replace(/\n+Prefer passing the current agent with `--agent <current_agent>`[^\n]*\n/g, "\n")
  result = result.replace(/\n+Use --agent to specify which agent to use for the session:[\s\S]*?\nkimaki send --channel [^\n]* --agent [^\n]*\n/g, "\n")
  result = result.replace(/ --agent <current_agent>/g, "")
  return result
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
  r = stripSectionBroken(r, "## scheduled sends and task management")
  r = stripSectionBroken(r, "## running dev servers with tunnel access")
  r = stripSectionBroken(r, "## reading other sessions")
  r = stripSectionBroken(r, "## running opencode commands via kimaki send")
  r = stripSectionBroken(r, "## switching agents in the current session")
  r = stripAgentOverrideInlines(r)
  r = r.replace(/\n{3,}/g, "\n\n")
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
