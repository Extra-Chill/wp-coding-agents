// Uses the real OpenCode executable and a loopback-only model fixture. No model
// account, bot restart, production prompt, or external provider is involved.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { mkdtemp, mkdir, writeFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

const root = await mkdtemp(join(tmpdir(), "managed-dispatch-"));
const captures = [];
let ownershipProbe = false;
const sentinel = join(root, "forbidden-command-ran");
const dummyKimaki = join(root, "project", "kimaki");
const raw = "The user is reading your messages from inside Discord, via kimaki.dev\n## creating worktrees\nUse kimaki send --worktree example.";
const server = createServer(async (request, response) => {
  let text = "";
  for await (const chunk of request) text += chunk;
  const body = JSON.parse(text);
  captures.push({ path: request.url, body });
  response.writeHead(200, { "content-type": "text/event-stream" });
  const callTool = ownershipProbe && !(body.messages ?? []).some(message => message.role === "tool");
  const delta = callTool
    ? { role: "assistant", tool_calls: [{ index: 0, id: "ownership-probe", type: "function", function: { name: "bash", arguments: JSON.stringify({ command: `${dummyKimaki} send --worktree example`, description: "Exercise ownership refusal" }) } }] }
    : { role: "assistant", content: "Verified." };
  const chunk = { id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] };
  response.write("data: " + JSON.stringify(chunk) + "\n\n");
  response.write("data: " + JSON.stringify({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: callTool ? "tool_calls" : "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }) + "\n\n");
  response.end("data: [DONE]\n\n");
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
try {
  for (const directory of ["home", "config", "data", "cache", "state", "project"]) await mkdir(join(root, directory));
  const config = {
    plugin: [process.env.DM_CONTEXT_FILTER_PLUGIN ?? resolve(import.meta.dirname, "../bridges/kimaki/plugins/dm-context-filter.ts"), join(root, "late-injection.ts")],
    provider: { fixture: { npm: "@ai-sdk/openai-compatible", name: "Loopback fixture", options: { baseURL: `http://127.0.0.1:${server.address().port}/v1`, apiKey: "fixture-only" }, models: { fixture: { name: "Fixture", limit: { context: 100000, output: 1000 } } } } },
    agent: {
      probe: { mode: "primary", model: "fixture/fixture", prompt: "Keep this repository instruction.\n" + raw, tools: { "*": false } },
      "ownership-probe": { mode: "primary", model: "fixture/fixture", prompt: "Exercise the managed tool policy.", tools: { "*": false, bash: true } },
      "reinject-system": { mode: "primary", model: "fixture/fixture", prompt: "REINJECT_SYSTEM_SENTINEL\n" + raw, tools: { "*": false } },
      "reinject-params": { mode: "primary", model: "fixture/fixture", prompt: "Exercise the provider guard.", tools: { "*": false } },
    },
  };
  await writeFile(join(root, "project", "opencode.json"), JSON.stringify(config));
  await writeFile(join(root, "late-injection.ts"), `const raw = ${JSON.stringify(raw)};
export default async () => ({
  "experimental.chat.system.transform": async (_input, output) => {
    if (output.system.some(block => block.includes("REINJECT_SYSTEM_SENTINEL"))) output.system.push(raw);
  },
  "chat.params": async (input, output) => {
    if (input.agent === "reinject-params") output.options = { instructions: raw };
  },
});\n`);
  await writeFile(dummyKimaki, `#!/bin/sh\ntouch '${sentinel}'\n`, { mode: 0o755 });
  const env = { ...process.env, HOME: join(root, "home"), XDG_CONFIG_HOME: join(root, "config"), XDG_DATA_HOME: join(root, "data"), XDG_CACHE_HOME: join(root, "cache"), XDG_STATE_HOME: join(root, "state"), OPENCODE_DISABLE_DEFAULT_PLUGINS: "true", OPENCODE_CONFIG: join(root, "project", "opencode.json"), OPENCODE_CONFIG_DIR: join(root, "config") };
  delete env.OPENCODE_CONFIG_CONTENT;
  const run = async (agent, continuation = false, expectFailure = false) => {
    const args = ["run", "--agent", agent, "--model", "fixture/fixture", "--format", "json", "--title", "Managed dispatch probe"];
    if (continuation) args.push("--continue");
    args.push(continuation ? "Continue the managed dispatch probe." : "Exercise the managed dispatch contract.");
    return await new Promise((resolve, reject) => {
      const child = spawn(process.env.OPENCODE_BIN ?? "opencode", args, { cwd: join(root, "project"), env, stdio: ["ignore", "pipe", "pipe"] });
      let output = "";
      child.stdout.on("data", data => { output += data; });
      child.stderr.on("data", data => { output += data; });
      const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error("OpenCode dispatch probe timed out: " + output.slice(-3000))); }, 60000);
      child.on("error", error => { clearTimeout(timer); reject(error); });
      child.on("exit", code => { clearTimeout(timer); code === 0 || expectFailure ? resolve(output) : reject(new Error(`OpenCode exited ${code}: ${output.slice(-3000)}`)); });
    });
  };
  await run("probe");
  await run("probe", true);
  assert(captures.length >= 2, "real provider requests were captured for fresh and resumed runs");
  for (const { body } of captures) {
    const system = (body.messages ?? []).filter(message => ["system", "developer"].includes(message.role)).map(message => message.content).join("\n");
    assert(system.includes("Managed Coding Runtime"));
    assert(system.includes("Keep this repository instruction."));
    assert(!system.includes("kimaki send"));
    assert(!system.includes("## creating worktrees"));
  }
  console.log(`PASS: real OpenCode fresh/resumed final HTTP payloads (${captures.length} requests)`);
  ownershipProbe = true;
  const start = captures.length;
  await run("ownership-probe");
  const toolResults = captures.slice(start).flatMap(capture => capture.body.messages ?? []).filter(message => message.role === "tool");
  assert(toolResults.some(message => JSON.stringify(message.content).includes("ownership guard")), "real tool refusal reaches the provider continuation");
  await assert.rejects(access(sentinel), { code: "ENOENT" }, "the forbidden executable never ran");
  console.log("PASS: real OpenCode rejects the forbidden coding command before execution");
  ownershipProbe = false;
  for (const agent of ["reinject-system", "reinject-params"]) {
    const before = captures.length;
    const diagnostic = await run(agent, false, true);
    assert(diagnostic.includes("dispatch guard"), `${agent}: actionable refusal surfaced`);
    assert.equal(captures.length, before, `${agent}: no provider request escaped`);
  }
  console.log("PASS: real late-hook reinjection refused before HTTP dispatch");
} finally {
  await new Promise(resolve => server.close(resolve));
  await rm(root, { recursive: true, force: true });
}
