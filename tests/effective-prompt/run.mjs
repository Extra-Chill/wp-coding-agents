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
//      kimaki upgrade that introduces new --worktree or project-routing
//      language fails the next test run.
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
//     on fenced bash comments). The harness keeps baseline output available
//     as diff evidence, but leak detection is the correctness gate.
//   - triggers: array of { name, pattern }. Defaults to Data Machine-owned
//     Kimaki policy sections that must not survive the filter.
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

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, unlinkSync } from "node:fs"
import { execSync } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { homedir } from "node:os"

import { currentFilterMessageText, currentFilterSystemBlocks, filters } from "./filters.mjs"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const SNAPSHOT_DIR = join(__dirname, "__snapshots__")
const SCENARIO_DIR = join(__dirname, "scenarios")
const KIMAKI_DIST_DIR = process.env.KIMAKI_DIST_DIR || join(execSync("npm root -g", { encoding: "utf8" }).trim(), "kimaki", "dist")
const { getOpencodeSystemMessage } = await import(pathToFileURL(join(KIMAKI_DIST_DIR, "system-message.js")).href)
const { store } = await import(pathToFileURL(join(KIMAKI_DIST_DIR, "store.js")).href)

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
  { name: "permissions",        pattern: "^## permissions$"                         },
  { name: "upgrade",            pattern: "^## upgrading kimaki$"                    },
  { name: "scheduler",          pattern: "^## scheduled sends and task management$" },
  { name: "site-runtime",       pattern: "^## running dev servers with tunnel access$" },
  { name: "session-history",    pattern: "^## reading other sessions$"              },
  { name: "session-start",      pattern: "^## starting new sessions from CLI$"       },
  { name: "slash-fanout",       pattern: "^## running opencode commands via kimaki send$" },
  { name: "agent-switch",       pattern: "^## switching agents in the current session$" },
  { name: "worktree-create",    pattern: "^## creating worktrees$"                  },
  { name: "cross-project",      pattern: "^## cross-project commands$"              },
  { name: "session-wait",       pattern: "^## waiting for a session to finish$"      },
  { name: "kimaki-worktree",    pattern: "\\bkimaki send\\b.*\\b--worktree\\b"    },
  { name: "kimaki-cwd",         pattern: "\\bkimaki send\\b.*\\b--cwd\\b"         },
  { name: "kimaki-send",        pattern: "\\bkimaki send\\b"                      },
  { name: "kimaki-project",     pattern: "\\bkimaki project (?:list|add|create)\\b" },
  { name: "kimaki-send-project", pattern: "\\bkimaki send\\b.*\\b--project\\b"     },
  { name: "kimaki-tunnel",      pattern: "\\bkimaki tunnel\\b"                     },
  { name: "homeboy-hardcode",   pattern: "\\bHomeboy\\b"                           },
  { name: "dmc-hardcode",       pattern: "\\bData Machine Code\\b"                 },
  { name: "global-tunnel-url",  pattern: "\\bdev\\.chubes\\.net\\b"                },
  { name: "helper-fanout",      pattern: "spawn(?:ed)? .*helper sessions"           },
  { name: "kimaki-generic-section", pattern: "^## (?:showing diffs|uploading files to discord|requesting files from the user|archiving the current thread|aborting a session|discord user mentions|generating audio from text|markdown formatting|Callouts in Kimaki Discord)$" },
  { name: "kimaki-command",         pattern: "\\bkimaki (?:send|session|project|tunnel|upload-to-discord|tts|task)\\b" },
  { name: "generic-skill-entry",    pattern: "<available_skills>|<skill>|</skill>|<name>(?!upgrade-wp-coding-agents</name>)" },
  { name: "external-diff-surface",  pattern: "\\b(?:critique\\.work|(?:bunx )?critique)\\b" },
]

// The current filter replaces Kimaki's generated bridge prompt and preserves
// other system blocks. Any trigger word appearing in the filtered Kimaki output
// is a real leak that needs investigation, not an intentional appendix.
const DEFAULT_ALLOW_LEAK_SECTIONS = []

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
  // wp-coding-agents managed Kimaki services run with --no-critique, so the
  // effective prompt harness should exercise that managed startup contract.
  critiqueEnabled: false,
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
// HOME normalization.
//
// Kimaki's live system prompt interpolates the local $HOME into a few
// instructions (e.g. the "debugging kimaki issues" log path
// `<home>/.kimaki/kimaki.log`). Without canonicalizing those paths, the
// committed snapshots are pinned to whatever home the author rendered them
// on, and the test fails with spurious "snapshot drift" on every other
// machine (every VPS: /home/<user>, /root; every other contributor's Mac).
//
// We replace the local home dir — and the common system home roots — with a
// stable `$HOME` token before snapshotting, leak detection, and diffing, so
// the test asserts on prompt *content*, not host identity.
// ---------------------------------------------------------------------------

function normalizeHome(text) {
  if (typeof text !== "string") return text
  let out = text
  const home = homedir()
  if (home && home !== "/") {
    out = out.split(home).join("$HOME")
  }
  // Catch home-dir paths that don't match the current process home (e.g. a
  // snapshot rendered under a different account than the one running the
  // test). These cover the platform-conventional home roots.
  out = out.replace(/\/Users\/[^/\s`"']+/g, "$HOME")
  out = out.replace(/\/home\/[^/\s`"']+/g, "$HOME")
  out = out.replace(/\/root(?=\/\.kimaki\b)/g, "$HOME")
  return out
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

async function runScenario(name, scenario) {
  if (ONLY && name !== ONLY) return { name, skipped: true }

  const filterFn = filters[scenario.filter]
  if (!filterFn) throw new Error(`scenario ${name}: unknown filter "${scenario.filter}"`)
  const baselineFn = filters[scenario.baseline]
  if (!baselineFn) throw new Error(`scenario ${name}: unknown baseline "${scenario.baseline}"`)

  const previousCritiqueEnabled = store.getState().critiqueEnabled
  let raw
  try {
    if (typeof scenario.critiqueEnabled === "boolean") {
      store.setState({ critiqueEnabled: scenario.critiqueEnabled })
    }
    raw = getOpencodeSystemMessage(scenario.args)
  } finally {
    store.setState({ critiqueEnabled: previousCritiqueEnabled })
  }
  // Canonicalize host-specific home-dir paths before any snapshot, leak
  // detection, or diff so the test is portable across machines. Filters run
  // on the normalized prompt too — they only strip content sections, never
  // home paths, so normalizing first keeps filter behavior identical while
  // making the recorded raw snapshot host-independent.
  raw = normalizeHome(raw)
  const baselineOut = normalizeHome(await baselineFn(raw))
  const filteredOut = normalizeHome(await filterFn(raw))

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
  if (baselineLeaks.length === 0 && filteredLeaks.length === 0) {
    // Both filters strip cleanly — nothing to assert about improvement
    // beyond size. Fine.
  } else if (filteredLeaks.length > baselineLeaks.length) {
    failures.push(
      `current filter leaks more (${filteredLeaks.length}) than baseline (${baselineLeaks.length}) — regression`,
    )
  }
  if (scenario.filter === "current") {
    const sentinelBlock = "## Sentinel Non-Kimaki System Block\n\nThis block represents composed AGENTS guidance."
    const transformedBlocks = await currentFilterSystemBlocks([sentinelBlock, raw])
    if (transformedBlocks[0] !== sentinelBlock) {
      failures.push("current filter changed a non-Kimaki system block")
    }
    if (transformedBlocks.length !== 2) {
      failures.push(`current filter returned ${transformedBlocks.length} system blocks for a two-block input`)
    }

    const joinedSystemPrefix = "## Sentinel Joined System Prefix\n\nThis block represents composed Data Machine AGENTS guidance."
    const joinedSystemInput = `${joinedSystemPrefix}\n\n${raw}`
    const joinedSystemBlocks = await currentFilterSystemBlocks([joinedSystemInput])
    const joinedSystemOut = joinedSystemBlocks.join("\n")
    const joinedSystemLeaks = detectLeaks(joinedSystemOut, scenario.triggers, scenario.allowLeakInSection)
    if (!joinedSystemOut.includes(joinedSystemPrefix)) {
      failures.push("current filter dropped the non-Kimaki prefix from a joined final system block")
    }
    if (!joinedSystemOut.includes("## Kimaki Discord Bridge")) {
      failures.push("current filter did not insert the managed bridge prompt into a joined final system block")
    }
    if (joinedSystemLeaks.length > 0) {
      failures.push(`current joined final system transform has ${joinedSystemLeaks.length} trigger leaks (expected 0)`)
    }

    const transformedMessageText = await currentFilterMessageText(raw)
    const messageLeaks = detectLeaks(transformedMessageText, scenario.triggers, scenario.allowLeakInSection)
    if (messageLeaks.length > 0) {
      failures.push(`current message transform has ${messageLeaks.length} trigger leaks (expected 0)`)
    }
    if (transformedMessageText !== filteredOut) {
      failures.push("current system and message transforms disagree for the Kimaki prompt")
    }
    const sentinelMessageText = await currentFilterMessageText(sentinelBlock)
    if (sentinelMessageText !== sentinelBlock) {
      failures.push("current message transform changed a non-Kimaki text part")
    }
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
  const delta = r.stripped_filtered - r.stripped_baseline
  const deltaDirection = delta >= 0 ? "more" : "fewer"
  console.log(`  delta    : current strips ${fmt(Math.abs(delta))} ${deltaDirection} chars than baseline (~${Math.abs(Math.round(delta / 4))} tokens)`)
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
const results = []
for (const [name, scenario] of scenarios) {
  results.push(await runScenario(name, scenario))
}

let failed = 0
for (const r of results) {
  printResult(r)
  if (!r.skipped && r.failures.length > 0) failed++
}

// Clean up .actual diff intermediates on a fully successful run so they do
// not litter the working tree (issue #134). On any failure, leave them in
// place so the reviewer can diff against the canonical snapshot.
if (failed === 0) {
  for (const f of readdirSync(SNAPSHOT_DIR)) {
    if (f.endsWith(".actual")) {
      try { unlinkSync(join(SNAPSHOT_DIR, f)) } catch {}
    }
  }
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
