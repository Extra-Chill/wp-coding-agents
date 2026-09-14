// tests/dm-agent-sync.mjs — lifecycle tests for the Kimaki DM memory sync plugin.

import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
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
  const stateDirectory = join(directory, "state")
  await writeFile(recorder, `#!/bin/sh
printf x >> "$DM_COMPOSE_COUNT"
sleep 0.15
`)
  await chmod(recorder, 0o755)
  await writeFile(count, "")
  await mkdir(stateDirectory)
  await writeFile(worker, `
const { default: dmAgentSync } = await import(process.env.DM_AGENT_SYNC_MODULE)
const plugin = await dmAgentSync({})
await plugin.config({ instructions: ["/tmp/datamachine-site/agents/intelligence-chubes4/SOUL.md"] })
if (process.env.DM_READY_FILE) {
  const { writeFile } = await import("node:fs/promises")
  await writeFile(process.env.DM_READY_FILE, "ready")
}
if (process.env.DM_START_FILE) {
  const { access } = await import("node:fs/promises")
  while (true) {
    try {
      await access(process.env.DM_START_FILE)
      break
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 5))
    }
  }
}
await plugin["chat.message"]({ sessionID: process.env.DM_SESSION_ID }, {})
`)

  const runWorker = (sessionID, executable = recorder, composeCount = count, timeout = "1000", stateDirectoryOverride = stateDirectory, startFile = "", readyFile = "") => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [worker], {
      env: {
        ...process.env,
        DATAMACHINE_SITE_PATH: sitePath,
        DATAMACHINE_WP_TRANSPORT_JSON: JSON.stringify([executable]),
        DATAMACHINE_AGENT_SLUG: "intelligence-chubes4",
        DATAMACHINE_COMPOSE_TIMEOUT_MS: timeout,
        DATAMACHINE_COMPOSE_STATE_DIR: stateDirectoryOverride,
        DM_COMPOSE_COUNT: composeCount,
        DM_AGENT_SYNC_MODULE: new URL("../bridges/kimaki/plugins/dm-agent-sync.ts", import.meta.url).href,
        DM_SESSION_ID: sessionID,
        DM_READY_FILE: readyFile,
        DM_START_FILE: startFile,
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

  const scopeFor = (executable) => createHash("sha256").update(JSON.stringify({
    agentSlug: "intelligence-chubes4",
    cwd: process.cwd(),
    home: process.env.HOME || "",
    path: process.env.PATH || "",
    sitePath,
    user: process.env.USER || process.env.LOGNAME || "",
    wpCli: [executable],
    wpCliCache: process.env.WP_CLI_CACHE_DIR || "",
    wpCliConfig: process.env.WP_CLI_CONFIG_PATH || "",
  })).digest("hex")
  const writeLease = async (stateDirectory, executable, owner, receipt) => {
    const scope = scopeFor(executable)
    const leasePath = join(stateDirectory, scope)
    await mkdir(leasePath, { recursive: true })
    await writeFile(join(leasePath, "owner"), JSON.stringify(owner))
    if (receipt) await writeFile(`${leasePath}.receipt`, JSON.stringify(receipt))
    return leasePath
  }
  const waitForFiles = async (files) => {
    const deadline = Date.now() + 5000
    while (Date.now() < deadline) {
      if (await Promise.all(files.map((file) => access(file).then(() => true, () => false))).then((ready) => ready.every(Boolean))) return
      await new Promise((resolve) => setTimeout(resolve, 5))
    }
    throw new Error(`workers did not become ready: ${files.join(", ")}`)
  }

  // Three independent processes race to reclaim the same expired lease. The
  // stale receipt must not be reused by the replacement operation.
  const staleStateDirectory = join(directory, "stale-state")
  await mkdir(staleStateDirectory)
  const staleOperation = "expired-operation"
  const staleLeasePath = await writeLease(staleStateDirectory, failingRecorder, {
    deadlineAt: Date.now() - 1,
    operationId: staleOperation,
    token: "expired-token",
  }, {
    completedAt: Date.now(),
    operationId: staleOperation,
    result: "refreshed",
  })
  const staleFailureCount = join(directory, "stale-failure-count")
  const staleOutputs = await Promise.all([
    runWorker("stale-one", failingRecorder, staleFailureCount, "1000", staleStateDirectory),
    runWorker("stale-two", failingRecorder, staleFailureCount, "1000", staleStateDirectory),
    runWorker("stale-three", failingRecorder, staleFailureCount, "1000", staleStateDirectory),
  ])
  assert.equal((await readFile(staleFailureCount, "utf8")).length, 1)
  assert.equal(staleOutputs.filter((output) => output.includes("memory compose failed")).length, 1)
  assert.equal(staleOutputs.filter((output) => output.includes("reused fresh Data Machine memory")).length, 0)
  assert.equal(staleOutputs.filter((output) => output.includes("memory compose stale fallback")).length, 2)
  await access(staleLeasePath)

  // Waiters use the owner's recorded deadline, not their shorter local timeout.
  const activeStateDirectory = join(directory, "active-state")
  await mkdir(activeStateDirectory)
  const activeLeasePath = await writeLease(activeStateDirectory, recorder, {
    deadlineAt: Date.now() + 1500,
    operationId: "active-operation",
    token: "active-token",
  })
  const activeStartedAt = Date.now()
  const activeCount = join(directory, "active-count")
  const activeStartFile = join(directory, "active-start")
  const activeReadyFiles = [join(directory, "active-one-ready"), join(directory, "active-two-ready")]
  const activeWorkers = [
    runWorker("active-one", recorder, activeCount, "10", activeStateDirectory, activeStartFile, activeReadyFiles[0]),
    runWorker("active-two", recorder, activeCount, "500", activeStateDirectory, activeStartFile, activeReadyFiles[1]),
  ]
  await waitForFiles(activeReadyFiles)
  await writeFile(activeStartFile, "start")
  const activeOutputs = await Promise.all(activeWorkers)
  assert.ok(Date.now() - activeStartedAt >= 1200)
  assert.equal(activeOutputs.filter((output) => output.includes("memory compose stale fallback")).length, 2)
  const recoveryStartFile = join(directory, "recovery-start")
  const recoveryReadyFiles = [join(directory, "recovery-one-ready"), join(directory, "recovery-two-ready")]
  const recoveryWorkers = [
    runWorker("recovery-one", recorder, activeCount, "500", activeStateDirectory, recoveryStartFile, recoveryReadyFiles[0]),
    runWorker("recovery-two", recorder, activeCount, "500", activeStateDirectory, recoveryStartFile, recoveryReadyFiles[1]),
  ]
  await waitForFiles(recoveryReadyFiles)
  await writeFile(recoveryStartFile, "start")
  const recoveryOutputs = await Promise.all(recoveryWorkers)
  assert.equal((await readFile(activeCount, "utf8")).length, 1)
  assert.equal(recoveryOutputs.filter((output) => output.includes("refreshed Data Machine memory")).length, 1)
  assert.equal(recoveryOutputs.filter((output) => output.includes("reused fresh Data Machine memory")).length, 1, recoveryOutputs.join("\n"))
  await rm(activeLeasePath, { recursive: true, force: true })

  // A malformed state path is bounded fallback, never recursive reacquisition.
  const errorStateDirectory = join(directory, "error-state")
  await mkdir(errorStateDirectory)
  await writeFile(join(errorStateDirectory, scopeFor(recorder)), "not a lease directory")
  const errorStartedAt = Date.now()
  const errorOutput = await runWorker("error", recorder, join(directory, "unexpected-error-count"), "25", errorStateDirectory)
  assert.ok(Date.now() - errorStartedAt < 2000)
  assert.ok(errorOutput.includes("memory compose stale fallback"))
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
