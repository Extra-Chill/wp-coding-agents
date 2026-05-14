// tests/dm-agent-sync.mjs — unit smoke tests for the Kimaki DM agent sync plugin.

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

const agentsJson = JSON.stringify([
  { agent_id: 1, agent_slug: "franklin", agent_name: "Franklin", owner_id: 1, status: "active" },
  { agent_id: 2, agent_slug: "julia", agent_name: "Julia", owner_id: 1, status: "active" },
])

const commonResponses = [
  [/^command -v wp$/, output("/usr/local/bin/wp")],
  [/^wp --path=\/tmp\/datamachine-site datamachine memory compose/, output("composed")],
  [/^wp --path=\/tmp\/datamachine-site datamachine agents list/, output(`${agentsJson}\nTotal: 2 agent(s).`)],
  [/--agent=franklin /, output(JSON.stringify({ agent_slug: "franklin", relative_files: ["SITE.md", "SOUL.md"] }))],
  [/--agent=julia /, output(JSON.stringify({ agent_slug: "julia", relative_files: ["SITE.md", "MEMORY.md"] }))],
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
  assert.match(config.agent.build.prompt, /\{file:\/tmp\/datamachine-site\/AGENTS\.md\}/)
  assert.match(config.agent.plan.prompt, /\{file:\/tmp\/datamachine-site\/SOUL\.md\}/)
  assert.equal(config.agent.build.model, "anthropic/claude-opus-4-7")
  assert.match(config.agent.franklin.prompt, /\{file:\/tmp\/datamachine-site\/SITE\.md\}/)
  assert.match(config.agent.julia.description, /Data Machine agent: Julia/)
  assert.ok(warnings.some((line) => line.includes("registered 2 Data Machine agent(s)")))
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
  assert.match(config.agent.build.prompt, /\{file:\/tmp\/datamachine-site\/SOUL\.md\}/)
  assert.match(config.agent.plan.prompt, /\{file:\/tmp\/datamachine-site\/SOUL\.md\}/)
}

{
  const config = {
    agent: {
      build: { prompt: "custom prompt" },
    },
  }
  await runConfig(config, commonResponses)
  assert.equal(config.agent.build.prompt, "custom prompt")
  assert.match(config.agent.plan.prompt, /\{file:\/tmp\/datamachine-site\/SOUL\.md\}/)
}

{
  const config = {}
  const warnings = await runConfig(config, [
    [/^command -v wp$/, output("/usr/local/bin/wp")],
    [/^wp --path=\/tmp\/datamachine-site datamachine memory compose/, output("composed")],
    [/^wp --path=\/tmp\/datamachine-site datamachine agents list/, output("", 1, "db down")],
  ])
  assert.ok(warnings.some((line) => line.includes("agents list failed")))
  assert.equal(config.agent, undefined)
}

console.log("OK: dm-agent-sync injects DM prompts and logs failures")
