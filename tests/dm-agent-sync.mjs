// tests/dm-agent-sync.mjs — unit smoke tests for the Kimaki DM memory plugin.

import assert from "node:assert/strict"
import dmAgentSync from "../bridges/kimaki/plugins/dm-agent-sync.ts"

const sitePath = "/tmp/datamachine-site"
process.env.DATAMACHINE_SITE_PATH = sitePath

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

const commonResponses = [
  [/^command -v wp$/, output("/usr/local/bin/wp")],
  [/^wp --path=\/tmp\/datamachine-site datamachine memory compose/, output("composed")],
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
  assert.deepEqual(warnings, [])
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
    [/^wp --path=\/tmp\/datamachine-site datamachine memory compose/, output("", 1, "db down")],
  ])
  assert.ok(warnings.some((line) => line.includes("memory compose failed")))
  assert.equal(config.agent, undefined)
}

console.log("OK: dm-agent-sync refreshes memory without injecting agent prompts")
