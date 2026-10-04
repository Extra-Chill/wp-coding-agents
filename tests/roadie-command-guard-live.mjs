// tests/roadie-command-guard-live.mjs — the guard refuses inside real OpenCode.
//
// Uses the real OpenCode executable and a loopback-only model fixture. The
// model asks the bash tool to run `roadie send --worktree`; the managed guard
// must refuse before the executable runs, and the refusal must reach the
// model as a tool result. No model account, bot, or external provider is used.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { mkdtemp, mkdir, writeFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

const root = await mkdtemp(join(tmpdir(), "roadie-guard-"));
const captures = [];
const sentinel = join(root, "forbidden-command-ran");
const dummyRoadie = join(root, "project", "roadie");
const server = createServer(async (request, response) => {
  let text = "";
  for await (const chunk of request) text += chunk;
  const body = JSON.parse(text);
  captures.push(body);
  response.writeHead(200, { "content-type": "text/event-stream" });
  const callTool = !(body.messages ?? []).some(message => message.role === "tool");
  const delta = callTool
    ? { role: "assistant", tool_calls: [{ index: 0, id: "ownership-probe", type: "function", function: { name: "bash", arguments: JSON.stringify({ command: `${dummyRoadie} send --worktree example --prompt build`, description: "Exercise ownership refusal" }) } }] }
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
    plugin: [resolve(import.meta.dirname, "../bridges/roadie/plugins/roadie-command-guard.ts")],
    provider: { fixture: { npm: "@ai-sdk/openai-compatible", name: "Loopback fixture", options: { baseURL: `http://127.0.0.1:${server.address().port}/v1`, apiKey: "fixture-only" }, models: { fixture: { name: "Fixture", limit: { context: 100000, output: 1000 } } } } },
    agent: {
      "ownership-probe": { mode: "primary", model: "fixture/fixture", prompt: "Exercise the managed tool policy.", tools: { "*": false, bash: true } },
    },
  };
  await writeFile(join(root, "project", "opencode.json"), JSON.stringify(config));
  await writeFile(dummyRoadie, `#!/bin/sh\ntouch '${sentinel}'\n`, { mode: 0o755 });
  const env = { ...process.env, HOME: join(root, "home"), XDG_CONFIG_HOME: join(root, "config"), XDG_DATA_HOME: join(root, "data"), XDG_CACHE_HOME: join(root, "cache"), XDG_STATE_HOME: join(root, "state"), OPENCODE_DISABLE_DEFAULT_PLUGINS: "true", OPENCODE_CONFIG: join(root, "project", "opencode.json"), OPENCODE_CONFIG_DIR: join(root, "config") };
  delete env.OPENCODE_CONFIG_CONTENT;
  const output = await new Promise((resolvePromise, reject) => {
    const args = ["run", "--agent", "ownership-probe", "--model", "fixture/fixture", "--format", "json", "--title", "Roadie guard probe", "Exercise the managed dispatch contract."];
    const child = spawn(process.env.OPENCODE_BIN ?? "opencode", args, { cwd: join(root, "project"), env, stdio: ["ignore", "pipe", "pipe"] });
    let text = "";
    child.stdout.on("data", data => { text += data; });
    child.stderr.on("data", data => { text += data; });
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error("OpenCode guard probe timed out: " + text.slice(-3000))); }, 60000);
    child.on("error", error => { clearTimeout(timer); reject(error); });
    child.on("exit", code => { clearTimeout(timer); code === 0 ? resolvePromise(text) : reject(new Error(`OpenCode exited ${code}: ${text.slice(-3000)}`)); });
  });
  const toolResults = captures.flatMap(body => body.messages ?? []).filter(message => message.role === "tool");
  assert(toolResults.some(message => JSON.stringify(message.content).includes("ownership guard")), `real tool refusal reaches the provider continuation: ${output.slice(-1500)}`);
  await assert.rejects(access(sentinel), { code: "ENOENT" }, "the forbidden executable never ran");
  console.log("PASS: real OpenCode refuses `roadie send --worktree` before execution");
} finally {
  await new Promise(resolvePromise => server.close(resolvePromise));
  await rm(root, { recursive: true, force: true });
}
