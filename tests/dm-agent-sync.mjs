// tests/dm-agent-sync.mjs — lifecycle tests for the Kimaki DM memory sync plugin.

import assert from "node:assert/strict"
import { access, chmod, mkdtemp, readFile, writeFile } from "node:fs/promises"
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
  assert.ok(run.warnings.some((line) => line.includes("recomposed Data Machine memory in")))
  const warningCount = run.warnings.length
  await run.chat()
  assert.equal(run.warnings.length, warningCount)
})

await withEnv({
  DATAMACHINE_SITE_PATH: sitePath,
  DATAMACHINE_WP_TRANSPORT_JSON: '["false"]',
  DATAMACHINE_WP_CMD: undefined,
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

await withEnv({ DATAMACHINE_COMPOSE_TIMEOUT_MS: "10" }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "dm-agent-sync-"))
  const marker = join(directory, "compose-finished")
  const run = await loadPlugin()
  await withEnv({ DATAMACHINE_WP_TRANSPORT_JSON: JSON.stringify(["sh", "-c", `sleep 0.2; touch ${marker}`]) }, async () => {
    await run.config()
    const startedAt = Date.now()
    await run.chat()
    assert.ok(Date.now() - startedAt < 150)
  })
  await new Promise((resolve) => setTimeout(resolve, 250))
  await assert.rejects(access(marker))
  assert.ok(run.warnings.some((line) => line.includes("memory compose timed out")))
})

await withEnv({ DATAMACHINE_WP_CMD: "true", DATAMACHINE_WP_TRANSPORT_JSON: undefined }, async () => {
  const run = await loadPlugin()
  await run.config()
  await run.chat()
  assert.ok(run.warnings.some((line) => line.includes("recomposed Data Machine memory in")))
})

await withEnv({ DATAMACHINE_SITE_PATH: sitePath, DATAMACHINE_WP_CMD: undefined }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "dm agent sync spaces "))
  const executable = join(directory, "wp cli")
  const output = join(directory, "received args")
  await writeFile(executable, `#!/bin/sh\nprintf '%s\\n' "$@" > "$DM_SYNC_TEST_OUTPUT"\n`)
  await chmod(executable, 0o755)

  await withEnv({
    DATAMACHINE_WP_TRANSPORT_JSON: JSON.stringify([executable, "fixed argument with spaces"]),
    DM_SYNC_TEST_OUTPUT: output,
  }, async () => {
    const run = await loadPlugin()
    await run.config()
    await run.chat()
    assert.ok(run.warnings.some((line) => line.includes("recomposed Data Machine memory in")))
  })

  const args = (await readFile(output, "utf8")).trim().split("\n")
  assert.deepEqual(args, [
    "fixed argument with spaces",
    "datamachine",
    "memory",
    "compose",
    `--path=${sitePath}`,
    "--allow-root",
  ])
})

console.log("OK: dm-agent-sync runs bounded WordPress composition only for the first chat message per session")
