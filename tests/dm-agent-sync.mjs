// tests/dm-agent-sync.mjs — lifecycle tests for the Kimaki DM memory sync plugin.

import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { access, chmod, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import dmAgentSync from "../bridges/kimaki/plugins/dm-agent-sync.ts"

const sitePath = "/tmp/datamachine-site"

async function withEnv(env, callback) {
  const previous = {}
  for (const key of Object.keys(env)) {
    previous[key] = process.env[key]
    if (env[key] === undefined) delete process.env[key]
    else process.env[key] = env[key]
  }
  try {
    return await callback()
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
}

async function loadPlugin(config = {}) {
  const warnings = []
  const originalWarn = console.warn
  const plugin = await dmAgentSync({})
  return {
    async config() {
      console.warn = (message) => warnings.push(String(message))
      try {
        await plugin.config(config)
      } finally {
        console.warn = originalWarn
      }
    },
    async chat(sessionID = "session-1") {
      console.warn = (message) => warnings.push(String(message))
      try {
        await plugin["chat.message"]({ sessionID }, {})
      } finally {
        console.warn = originalWarn
      }
    },
    warnings,
  }
}

await withEnv({
  DATAMACHINE_SITE_PATH: sitePath,
  DATAMACHINE_WP_TRANSPORT_JSON: '["true"]',
  DATAMACHINE_WP_CMD: undefined,
  DATAMACHINE_AGENT_SLUG: "intelligence-chubes4",
  EXTERNAL_WORDPRESS: undefined,
}, async () => {
  const config = { instructions: ["/tmp/datamachine-site/agents/intelligence-chubes4/SOUL.md"] }
  const run = await loadPlugin(config)
  await run.config()

  // Mirrors `opencode models`: config setup has no shell or WordPress work and
  // leaves setup/upgrade-managed instruction paths untouched.
  assert.deepEqual(config.instructions, ["/tmp/datamachine-site/agents/intelligence-chubes4/SOUL.md"])
  assert.equal(run.warnings.length, 0)

  await run.chat()
  assert.ok(run.warnings.some((line) => line.includes("refreshed Data Machine memory in")))
  const warningCount = run.warnings.length
  await run.chat()
  assert.equal(run.warnings.length, warningCount)
})

{
  const directory = await mkdtemp(join(tmpdir(), "dm-agent-sync-concurrent-"))
  const recorder = join(directory, "compose")
  const count = join(directory, "count")
  const worker = join(directory, "worker.mjs")
  await writeFile(recorder, `#!/bin/sh
printf x >> "$DM_COMPOSE_COUNT"
sleep 0.15
`)
  await chmod(recorder, 0o755)
  await writeFile(worker, `
const { default: dmAgentSync } = await import(process.env.DM_AGENT_SYNC_MODULE)
const plugin = await dmAgentSync({})
await plugin.config({ instructions: ["/tmp/datamachine-site/agents/intelligence-chubes4/SOUL.md"] })
await plugin["chat.message"]({ sessionID: process.env.DM_SESSION_ID }, {})
`)

  const runWorker = (sessionID, executable = recorder, composeCount = count) => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [worker], {
      env: {
        ...process.env,
        DATAMACHINE_SITE_PATH: sitePath,
        DATAMACHINE_WP_TRANSPORT_JSON: JSON.stringify([executable]),
        DATAMACHINE_AGENT_SLUG: "intelligence-chubes4",
        DATAMACHINE_COMPOSE_TIMEOUT_MS: "1000",
        DM_COMPOSE_COUNT: composeCount,
        DM_AGENT_SYNC_MODULE: new URL("../bridges/kimaki/plugins/dm-agent-sync.ts", import.meta.url).href,
        DM_SESSION_ID: sessionID,
        EXTERNAL_WORDPRESS: "",
      },
    })
    let output = ""
    child.stderr.on("data", (chunk) => { output += chunk })
    child.on("error", reject)
    child.on("close", (code) => code === 0 ? resolve(output) : reject(new Error(`worker exited ${code}: ${output}`)))
  })

  const outputs = await Promise.all([runWorker("one"), runWorker("two"), runWorker("three")])
  assert.equal((await readFile(count, "utf8")).length, 1)
  assert.equal(outputs.filter((output) => output.includes("refreshed Data Machine memory")).length, 1)
  assert.equal(outputs.filter((output) => output.includes("reused fresh Data Machine memory")).length, 2)

  const failingRecorder = join(directory, "compose-failure")
  const failureCount = join(directory, "failure-count")
  await writeFile(failingRecorder, `#!/bin/sh
printf x >> "$DM_COMPOSE_COUNT"
sleep 0.15
exit 1
`)
  await chmod(failingRecorder, 0o755)
  const failureOutputs = await Promise.all([
    runWorker("failure-one", failingRecorder, failureCount),
    runWorker("failure-two", failingRecorder, failureCount),
  ])
  assert.equal((await readFile(failureCount, "utf8")).length, 1)
  assert.equal(failureOutputs.filter((output) => output.includes("memory compose failed")).length, 1)
  assert.equal(failureOutputs.filter((output) => output.includes("memory compose stale fallback")).length, 1)
}

await withEnv({
  DATAMACHINE_SITE_PATH: sitePath,
  DATAMACHINE_WP_TRANSPORT_JSON: '["false"]',
  DATAMACHINE_AGENT_SLUG: "intelligence-chubes4",
}, async () => {
  const run = await loadPlugin()
  await run.config()
  await run.chat()
  assert.ok(run.warnings.some((line) => line.includes("memory compose failed")))
})

await withEnv({ EXTERNAL_WORDPRESS: "true", DATAMACHINE_WP_TRANSPORT_JSON: '["false"]' }, async () => {
  const run = await loadPlugin()
  await run.config()
  await run.chat()
  assert.equal(run.warnings.length, 0)
})

await withEnv({
  DATAMACHINE_SITE_PATH: sitePath,
  DATAMACHINE_WP_TRANSPORT_JSON: "[]",
  DATAMACHINE_WP_CMD: "false",
  DATAMACHINE_AGENT_SLUG: "intelligence-chubes4",
}, async () => {
  const run = await loadPlugin()
  await run.config()
  await run.chat()
  assert.equal(run.warnings.length, 0)
})

await withEnv({
  DATAMACHINE_SITE_PATH: sitePath,
  DATAMACHINE_WP_TRANSPORT_JSON: undefined,
  DATAMACHINE_WP_CMD: "true",
  DATAMACHINE_AGENT_SLUG: "intelligence-chubes4",
}, async () => {
  const run = await loadPlugin()
  await run.config()
  await run.chat()
  assert.ok(run.warnings.some((line) => line.includes("refreshed Data Machine memory in")))
})

await withEnv({ DATAMACHINE_COMPOSE_TIMEOUT_MS: "10" }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "dm-agent-sync-"))
  const marker = join(directory, "compose-finished")
  const run = await loadPlugin()
  await withEnv({
    DATAMACHINE_COMPOSE_TIMEOUT_MS: "10",
    DATAMACHINE_WP_TRANSPORT_JSON: JSON.stringify(["sh", "-c", `sleep 0.2; touch ${marker}`]),
  }, async () => {
    await run.config()
    const startedAt = Date.now()
    await run.chat()
    assert.ok(Date.now() - startedAt < 150)
  })
  await new Promise((resolve) => setTimeout(resolve, 250))
  await assert.rejects(access(marker))
  assert.ok(run.warnings.some((line) => line.includes("memory compose timed out")))
})

await withEnv({
  DATAMACHINE_WP_CMD: "false",
  DATAMACHINE_AGENT_SLUG: "agent with spaces",
}, async () => {
  const directory = await mkdtemp(join(tmpdir(), "dm-agent-sync-argv-"))
  const binDir = join(directory, "bin with spaces")
  const siteDir = join(directory, "site with spaces")
  const dump = join(directory, "argv.json")
  const recorder = join(binDir, "wp cli")
  await mkdir(binDir)
  await writeFile(recorder, `#!/bin/sh
python3 -c 'import json,os,sys; open(os.environ["DM_ARGV_DUMP"],"w").write(json.dumps(sys.argv[1:]))' "$@"
`)
  await chmod(recorder, 0o755)
  const run = await loadPlugin()
  await withEnv({
    DATAMACHINE_SITE_PATH: siteDir,
    DATAMACHINE_WP_TRANSPORT_JSON: JSON.stringify([recorder, "--flag with spaces"]),
    DM_ARGV_DUMP: dump,
  }, async () => {
    await run.config()
    await run.chat()
  })
  const argv = JSON.parse(await readFile(dump, "utf8"))
  assert.deepEqual(argv, [
    "--flag with spaces",
    "datamachine",
    "memory",
    "compose",
    "--agent=agent with spaces",
    `--path=${siteDir}`,
    "--allow-root",
  ])
})

console.log("OK: dm-agent-sync coalesces concurrent process refreshes and runs bounded composition once per session")
