// tests/effective-prompt/run.mjs — pluggable effective-prompt harness.
//
// Renders the kimaki opencode system prompt, runs a pluggable filter over
// it, snapshots the before/after to disk, diffs them, and asserts a set of
// pluggable invariants (no leaking trigger phrases, monotonic improvement
// over a baseline filter, etc).
//
// This is the regression artifact for everything we strip from the
// kimaki-shipped system prompt. Three things make it durable:
//
//   1. It loads the LIVE installed kimaki module (not a copy), so a
//      kimaki upgrade that introduces new --worktree language fails the
//      next test run.
//   2. It loads the LIVE plugin source from kimaki/plugins/, so a filter
//      change in this repo immediately reflows the snapshots.
//   3. It writes named .txt snapshots to __snapshots__/, so reviewers
//      can `git diff` to see exactly what changed in the rendered prompt
//      between commits — same workflow as jest snapshots, no jest dep.
//
// Pluggable knobs (per scenario file):
//
//   - args: the object passed to getOpencodeSystemMessage(). Lets the
//     harness exercise multi-agent, no-agent, with/without thread, etc.
//   - filter: name of a filter from filters.mjs. Default: "current"
//     (the real dm-context-filter from kimaki/plugins/).
//   - baseline: name of a baseline filter to compare against. Default:
//     "broken-stripsection" (the regex-only stripSection that misfires
//     on fenced bash comments). The harness asserts the baseline
//     strips strictly LESS than the current filter.
//   - triggers: array of { name, pattern }. Default: worktree + --cwd.
//     Lines matching any trigger in the filtered output count as leaks.
//   - allowLeakInSection: array of section headings where trigger
//     matches are intentional (e.g. the appended Minion Routing note
//     intentionally references --cwd to point agents at it).
//
// Usage:
//
//   node tests/effective-prompt/run.mjs                # run all scenarios
//   node tests/effective-prompt/run.mjs --update       # write snapshots
//   node tests/effective-prompt/run.mjs --scenario=X   # run one
//
// Exit code: 0 on success, 1 on any assertion failure.

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from "node:fs"
import { execSync } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { getOpencodeSystemMessage } from "/Users/chubes/.nvm/versions/node/v24.13.1/lib/node_modules/kimaki/dist/system-message.js"
import { filters } from "./filters.mjs"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const SNAPSHOT_DIR = join(__dirname, "__snapshots__")
const SCENARIO_DIR = join(__dirname, "scenarios")

if (!existsSync(SNAPSHOT_DIR)) mkdirSync(SNAPSHOT_DIR, { recursive: true })

// ---------------------------------------------------------------------------
// CLI args.
// ---------------------------------------------------------------------------

const args = process.argv.slice(2)
const UPDATE = args.includes("--update")
const ONLY = args.find((a) => a.startsWith("--scenario="))?.split("=")[1]
const VERBOSE = args.includes("--verbose")

// ---------------------------------------------------------------------------
// Default scenarios — used when the scenarios dir is empty so the harness
// is useful out of the box. Real scenarios live as .json files in
// scenarios/ once the suite is seeded.
// ---------------------------------------------------------------------------

const DEFAULT_TRIGGERS = [
  { name: "worktree", pattern: "(?i)worktree" },
  { name: "--cwd",    pattern: "--cwd"        },
]

const DEFAULT_ALLOW_LEAK_SECTIONS = [
  // The filter intentionally appends this section with both `worktree` and
  // `--cwd` in it, pointing agents at DMC's workspace. Counting it as a
  // leak would defeat the purpose.
  "## Minion Session Routing",
]

const DEFAULT_SCENARIO = {
  description: "default opencode session, single project, two agents",
  args: {
    sessionId: "ses_EFFECTIVE_PROMPT_TEST",
    channelId: "1493345787894038649",
    guildId: "1493321868415996064",
    threadId: "1497759414470311967",
    channelTopic: "intelligence-chubes4 personal agent",
    agents: [
      { name: "build", description: "default coding agent" },
      { name: "plan",  description: "planning agent"      },
    ],
    username: "chubes",
  },
  filter: "current",
  baseline: "broken-stripsection",
  triggers: DEFAULT_TRIGGERS,
  allowLeakInSection: DEFAULT_ALLOW_LEAK_SECTIONS,
}

function loadScenarios() {
  if (!existsSync(SCENARIO_DIR)) return [["default", DEFAULT_SCENARIO]]
  const files = readdirSync(SCENARIO_DIR).filter((f) => f.endsWith(".json"))
  if (files.length === 0) return [["default", DEFAULT_SCENARIO]]
  return files.map((f) => {
    const name = f.replace(/\.json$/, "")
    const merged = { ...DEFAULT_SCENARIO, ...JSON.parse(readFileSync(join(SCENARIO_DIR, f), "utf8")) }
    return [name, merged]
  })
}

// ---------------------------------------------------------------------------
// Leak detection.
// ---------------------------------------------------------------------------

function compileTrigger(t) {
  // Support a tiny "(?i)" prefix to mark case-insensitive without forcing
  // every caller to know JS regex flag syntax in JSON.
  let src = t.pattern
  let flags = ""
  if (src.startsWith("(?i)")) { flags += "i"; src = src.slice(4) }
  return { name: t.name, re: new RegExp(src, flags) }
}

function findSectionForLine(lines, lineIdx) {
  for (let i = lineIdx; i >= 0; i--) {
    const m = lines[i].match(/^(#{1,6})\s+(.+)$/)
    if (m) return `${m[1]} ${m[2]}`
  }
  return "(top of prompt)"
}

function detectLeaks(text, triggers, allowSections) {
  const lines = text.split("\n")
  const compiled = triggers.map(compileTrigger)
  const allowSet = new Set(allowSections)
  const leaks = []
  for (let i = 0; i < lines.length; i++) {
    for (const t of compiled) {
      if (t.re.test(lines[i])) {
        const section = findSectionForLine(lines, i)
        if (!allowSet.has(section)) {
          leaks.push({ line: i + 1, trigger: t.name, section, text: lines[i] })
        }
        break
      }
    }
  }
  return leaks
}

// ---------------------------------------------------------------------------
// Snapshot + diff.
// ---------------------------------------------------------------------------

function snapshotPath(scenarioName, label) {
  return join(SNAPSHOT_DIR, `${scenarioName}.${label}.txt`)
}

function readSnapshot(path) {
  return existsSync(path) ? readFileSync(path, "utf8") : null
}

function writeSnapshot(path, content) {
  writeFileSync(path, content, "utf8")
}

function gitDiff(beforePath, afterPath) {
  try {
    execSync(`git --no-pager diff --no-index --no-color "${beforePath}" "${afterPath}"`, {
      stdio: "pipe",
    })
    return ""  // Files match.
  } catch (e) {
    // git diff exits 1 when files differ — stdout still has the diff.
    return e.stdout?.toString() || ""
  }
}

// ---------------------------------------------------------------------------
// Run one scenario.
// ---------------------------------------------------------------------------

function runScenario(name, scenario) {
  if (ONLY && name !== ONLY) return { name, skipped: true }

  const filterFn = filters[scenario.filter]
  if (!filterFn) throw new Error(`scenario ${name}: unknown filter "${scenario.filter}"`)
  const baselineFn = filters[scenario.baseline]
  if (!baselineFn) throw new Error(`scenario ${name}: unknown baseline "${scenario.baseline}"`)

  const raw = getOpencodeSystemMessage(scenario.args)
  const baselineOut = baselineFn(raw)
  const filteredOut = filterFn(raw)

  const baselineLeaks = detectLeaks(baselineOut, scenario.triggers, scenario.allowLeakInSection)
  const filteredLeaks = detectLeaks(filteredOut, scenario.triggers, scenario.allowLeakInSection)

  // Snapshot writes / compares.
  const beforePath = snapshotPath(name, "baseline")
  const afterPath  = snapshotPath(name, "filtered")
  const rawPath    = snapshotPath(name, "raw")

  const failures = []

  function checkSnapshot(path, label, content) {
    if (UPDATE) {
      writeSnapshot(path, content)
      return
    }
    const existing = readSnapshot(path)
    if (existing === null) {
      writeSnapshot(path, content)
      console.log(`  [snapshot] ${label} written (was missing)`)
      return
    }
    if (existing !== content) {
      failures.push(`${label} snapshot drift — run with --update to refresh`)
      // Write the actual to a sibling .actual file so reviewer can diff.
      writeSnapshot(path + ".actual", content)
    }
  }

  checkSnapshot(rawPath,    "raw",      raw)
  checkSnapshot(beforePath, "baseline", baselineOut)
  checkSnapshot(afterPath,  "filtered", filteredOut)

  // Invariants.
  if (filteredLeaks.length > 0) {
    failures.push(`filtered prompt has ${filteredLeaks.length} trigger leaks (expected 0)`)
  }
  if (filteredOut.length >= baselineOut.length) {
    failures.push(
      `filtered prompt (${filteredOut.length} chars) is not strictly smaller than baseline ` +
      `(${baselineOut.length} chars) — current filter is regressing on baseline`,
    )
  }
  if (baselineLeaks.length === 0 && filteredLeaks.length === 0) {
    // Both filters strip cleanly — nothing to assert about improvement
    // beyond size. Fine.
  } else if (filteredLeaks.length > baselineLeaks.length) {
    failures.push(
      `current filter leaks more (${filteredLeaks.length}) than baseline (${baselineLeaks.length}) — regression`,
    )
  }

  return {
    name,
    description: scenario.description,
    raw_chars: raw.length,
    baseline_chars: baselineOut.length,
    filtered_chars: filteredOut.length,
    stripped_baseline: raw.length - baselineOut.length,
    stripped_filtered: raw.length - filteredOut.length,
    baseline_leaks: baselineLeaks,
    filtered_leaks: filteredLeaks,
    failures,
    diffPath: { beforePath, afterPath },
  }
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

function fmt(n) { return n.toLocaleString() }

function printResult(r) {
  if (r.skipped) return
  console.log(`\n${"=".repeat(72)}`)
  console.log(`scenario: ${r.name}`)
  console.log(`  ${r.description}`)
  console.log(`${"=".repeat(72)}`)
  console.log(`  raw      : ${fmt(r.raw_chars)} chars`)
  console.log(`  baseline : ${fmt(r.baseline_chars)} chars (stripped ${fmt(r.stripped_baseline)}, ~${Math.round(r.stripped_baseline / 4)} tokens)`)
  console.log(`  filtered : ${fmt(r.filtered_chars)} chars (stripped ${fmt(r.stripped_filtered)}, ~${Math.round(r.stripped_filtered / 4)} tokens)`)
  console.log(`  delta    : current strips ${fmt(r.stripped_filtered - r.stripped_baseline)} more chars than baseline (+${Math.round((r.stripped_filtered - r.stripped_baseline) / 4)} tokens)`)
  console.log(`  baseline leaks: ${r.baseline_leaks.length}`)
  console.log(`  filtered leaks: ${r.filtered_leaks.length}`)

  if (r.filtered_leaks.length > 0 || VERBOSE) {
    if (r.filtered_leaks.length > 0) {
      console.log(`\n  Leaks in filtered output:`)
      for (const l of r.filtered_leaks) {
        console.log(`    L${l.line} [${l.trigger}] in ${l.section}`)
        console.log(`      ${l.text.slice(0, 100)}${l.text.length > 100 ? "…" : ""}`)
      }
    }
    if (VERBOSE && r.baseline_leaks.length > 0) {
      console.log(`\n  Leaks the baseline filter missed (current filter catches these):`)
      const baselineMissed = r.baseline_leaks.filter(
        (b) => !r.filtered_leaks.some((f) => f.line === b.line && f.text === b.text),
      )
      for (const l of baselineMissed.slice(0, 8)) {
        console.log(`    L${l.line} [${l.trigger}] in ${l.section}`)
        console.log(`      ${l.text.slice(0, 100)}${l.text.length > 100 ? "…" : ""}`)
      }
      if (baselineMissed.length > 8) {
        console.log(`    … and ${baselineMissed.length - 8} more`)
      }
    }
  }

  if (r.failures.length > 0) {
    console.log(`\n  FAIL:`)
    for (const f of r.failures) console.log(`    - ${f}`)
  } else {
    console.log(`\n  PASS`)
  }
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

const scenarios = loadScenarios()
const results = scenarios.map(([name, scenario]) => runScenario(name, scenario))

let failed = 0
for (const r of results) {
  printResult(r)
  if (!r.skipped && r.failures.length > 0) failed++
}

console.log(`\n${"=".repeat(72)}`)
if (failed === 0) {
  console.log(`OK — ${results.filter((r) => !r.skipped).length} scenario(s) passed`)
  console.log(`Snapshots: ${SNAPSHOT_DIR}`)
  console.log(`To see the side-by-side baseline-vs-filtered diff for any scenario:`)
  console.log(`  git --no-pager diff --no-index tests/effective-prompt/__snapshots__/<scenario>.baseline.txt tests/effective-prompt/__snapshots__/<scenario>.filtered.txt`)
  process.exit(0)
} else {
  console.log(`FAIL — ${failed} scenario(s) failed`)
  process.exit(1)
}
