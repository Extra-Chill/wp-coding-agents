// tests/dm-agent-sync.mjs — unit smoke tests for the Kimaki DM memory sync plugin.

import assert from "node:assert/strict"
import dmAgentSync from "../bridges/kimaki/plugins/dm-agent-sync.ts"

const sitePath = "/tmp/datamachine-site"
process.env.DATAMACHINE_SITE_PATH = sitePath
delete process.env.DATAMACHINE_WP_CMD
delete process.env.WP_CMD
delete process.env.DATAMACHINE_AGENT_SLUG

function output(stdout = "", exitCode = 0, stderr = "") {
  return {
    exitCode,
    stdout,
    stderr,
    async text() {
      return [stdout, stderr].filter(Boolean).join("\n")
    },
  }
}

function fakeShell(responses) {
  return (strings, ...values) => {
    const command = strings.reduce((acc, part, index) => acc + part + (values[index] ?? ""), "")
    return {
      quiet() {
        return this
      },
      nothrow() {
        for (const [pattern, result] of responses) {
          if (pattern.test(command)) {
            return Promise.resolve(result)
          }
        }
        return Promise.resolve(output("", 1, `unexpected command: ${command}`))
      },
    }
  }
}

async function runConfig(config, responses) {
  const warnings = []
  const originalWarn = console.warn
  console.warn = (message) => warnings.push(String(message))
  try {
    const plugin = await dmAgentSync({ $: fakeShell(responses) })
    await plugin.config(config)
  } finally {
    console.warn = originalWarn
  }
  return warnings
}

async function withEnv(env, callback) {
  const previous = {}
  for (const key of Object.keys(env)) {
    previous[key] = process.env[key]
    if (env[key] === undefined) {
      delete process.env[key]
    } else {
      process.env[key] = env[key]
    }
  }

  try {
    return await callback()
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) {
        delete process.env[key]
      } else {
        process.env[key] = value
      }
    }
  }
}

const commonResponses = [
  [/^command -v wp$/, output("/usr/local/bin/wp")],
  [/^sh -lc wp 'datamachine' 'memory' 'compose' '--path=\/tmp\/datamachine-site' '--allow-root'$/, output("composed")],
]

{
  const config = {
    model: "anthropic/claude-opus-4-7",
    agent: {
      build: { mode: "primary", model: "anthropic/claude-opus-4-7" },
      plan: { mode: "primary", model: "anthropic/claude-opus-4-7" },
    },
  }
  const warnings = await runConfig(config, commonResponses)
  assert.equal(config.agent.build.prompt, undefined)
  assert.equal(config.agent.plan.prompt, undefined)
  assert.equal(config.agent.build.model, "anthropic/claude-opus-4-7")
  assert.equal(config.agent.franklin, undefined)
  assert.equal(config.agent.julia, undefined)
  assert.ok(warnings.some((line) => line.includes("recomposed Data Machine memory")))
}

{
  const config = {
    agent: {
      build: { mode: "primary", tools: { bash: true } },
      plan: { mode: "primary" },
    },
  }
  await runConfig(config, commonResponses)
  assert.deepEqual(config.agent.build.tools, { bash: true })
  assert.equal(config.agent.build.prompt, undefined)
  assert.equal(config.agent.plan.prompt, undefined)
}

{
  const config = {
    agent: {
      build: { prompt: "custom prompt" },
    },
  }
  await runConfig(config, commonResponses)
  assert.equal(config.agent.build.prompt, "custom prompt")
  assert.equal(config.agent.plan, undefined)
}

{
  const config = {}
  const warnings = await runConfig(config, [
    [/^command -v wp$/, output("/usr/local/bin/wp")],
    [/^sh -lc wp 'datamachine' 'memory' 'compose' '--path=\/tmp\/datamachine-site' '--allow-root'$/, output("", 1, "db down")],
  ])
  assert.ok(warnings.some((line) => line.includes("memory compose failed")))
  assert.equal(config.agent, undefined)
}

await withEnv({ DATAMACHINE_WP_CMD: "custom-wp", DATAMACHINE_AGENT_SLUG: "intelligence-chubes4" }, async () => {
  const config = {}
  const warnings = await runConfig(config, [
    [/^sh -lc custom-wp 'datamachine' 'memory' 'compose' '--agent=intelligence-chubes4' '--path=\/tmp\/datamachine-site' '--allow-root'$/, output("composed")],
    [/^sh -lc custom-wp 'datamachine' 'memory' 'injectable-files' '--format=json' '--agent=intelligence-chubes4' '--path=\/tmp\/datamachine-site' '--allow-root'$/, output(JSON.stringify([
      { path: "/tmp/datamachine-site/AGENTS.md" },
      { path: "/tmp/datamachine-site/MEMORY.md" },
    ]))],
  ])
  assert.ok(warnings.some((line) => line.includes("recomposed Data Machine memory")))
  assert.deepEqual(config.instructions, ["/tmp/datamachine-site/AGENTS.md", "/tmp/datamachine-site/MEMORY.md"])
})

console.log("OK: dm-agent-sync recomposes DM memory without mutating OpenCode agents")
