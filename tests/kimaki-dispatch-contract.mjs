import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const pluginPath = resolve(import.meta.dirname, "../bridges/kimaki/plugins/dm-context-filter.ts");
const hooks = await (await import(pathToFileURL(pluginPath).href)).default({});
const raw = `The user is reading your messages from inside Discord, via kimaki.dev
## creating worktrees
Use kimaki send --worktree example to create a coding session.`;
const composed = "Repository instructions: use the registered coding runtime.";

// OpenCode retains this array and ignores the transform's return value.
const retained = [composed + "\n" + raw];
const output = { system: retained };
await hooks["experimental.chat.system.transform"]({}, output);
assert.equal(output.system, retained, "the caller's system array must keep its identity");
assert(!retained.join("\n").includes("kimaki send"), "retained dispatch instructions must be filtered");
assert(retained[0].includes(composed), "preserve composed repository guidance");
const suffix = "Additional component policy: preserve this too.";
const alreadyManaged = [retained[0] + "\n" + suffix];
const before = alreadyManaged[0];
await hooks["experimental.chat.system.transform"]({}, { system: alreadyManaged });
assert.equal(alreadyManaged[0], before, "canonical bridge text must not hide or remove unrelated suffixes");

const captured = [];
const server = createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  captured.push(JSON.parse(body));
  response.writeHead(200, { "content-type": "application/json" });
  response.end("{}");
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
try {
  const url = `http://127.0.0.1:${server.address().port}`;
  await fetch(url, { method: "POST", body: JSON.stringify({ instructions: retained.join("\n") }) });
  await fetch(url, { method: "POST", body: JSON.stringify({ messages: retained.map(content => ({ role: "system", content })) }) });
  for (const payload of captured) {
    assert(!JSON.stringify(payload).includes("kimaki send"));
    assert(JSON.stringify(payload).includes("Managed Coding Runtime"));
  }
} finally {
  await new Promise(resolve => server.close(resolve));
}
console.log("PASS: retained-array HTTP dispatch contract (instructions and system messages)");

const request = { sessionID: "probe", agent: "build", model: { providerID: "openai", id: "fixture" }, message: { id: "user-1", role: "user", system: raw } };
const fresh = { message: request.message, parts: [{ type: "text", text: "Discuss this literal: " + raw }] };
await hooks["chat.message"]({}, fresh);
assert(fresh.message.system.includes("Managed Coding Runtime"));
assert.equal(fresh.parts[0].text, "Discuss this literal: " + raw, "ordinary user text remains intact");

const resumed = { messages: [
  { info: { role: "user", system: raw }, parts: [{ type: "text", text: "Quoted source: " + raw }] },
  { info: { role: "user" }, parts: [{ type: "text", synthetic: true, text: raw }] },
] };
const ordinary = resumed.messages[0].parts[0].text;
await hooks["experimental.chat.messages.transform"]({}, resumed);
assert.equal(resumed.messages[0].parts[0].text, ordinary);
assert(!resumed.messages[0].info.system.includes("kimaki send"));
assert(!resumed.messages[1].parts[0].text.includes("kimaki send"));

const compacted = { context: [composed, raw], prompt: raw };
const retainedContext = compacted.context;
await hooks["experimental.session.compacting"]({}, compacted);
assert.equal(compacted.context, retainedContext);
assert.equal(compacted.context[0], composed);
assert(!JSON.stringify(compacted).includes("kimaki send"));
console.log("PASS: fresh, resumed, synthetic, and compaction instruction surfaces");

const system = [raw];
await hooks["experimental.chat.system.transform"](request, { system });
const params = { options: { instructions: raw } };
await hooks["chat.params"](request, params);
assert(!params.options.instructions.includes("kimaki send"));
params.options = { instructions: raw }; // A later plugin reassigns the options object.
await assert.rejects(hooks["chat.headers"](request, { headers: {} }), /dispatch guard/);

const reinjected = [raw];
await hooks["experimental.chat.system.transform"](request, { system: reinjected });
reinjected.push(raw); // A later system-transform plugin injects the old prompt.
await assert.rejects(hooks["chat.params"](request, { options: {} }), /dispatch guard/);
await hooks.event({ event: { type: "session.status", properties: { sessionID: "probe", status: { type: "idle" } } } });
await hooks["chat.headers"](request, { headers: {} });
console.log("PASS: later system and provider-option reinjection refuses dispatch");

for (const command of [
  "kimaki send --worktree example --prompt task",
  "kimaki send --channel 123 --prompt task",
  "/usr/local/bin/kimaki send --session session --prompt task",
  "env FOO=bar kimaki send --project /repo --prompt task",
  "env -C /tmp kimaki send --worktree example",
  "env -S 'kimaki send --worktree example'",
  "npx --yes kimaki send --worktree example",
  "npx --package kimaki kimaki send --worktree example",
  "pnpm exec kimaki send --worktree example",
  "npm exec --package=kimaki -- kimaki send --worktree example",
  "npx --call 'kimaki send --worktree example'",
  "bunx kimaki send --worktree=example",
  "bash -lc 'kimaki send --worktree example'",
  "sudo -u user kimaki send --worktree example",
  "timeout 10s kimaki send --worktree example",
  "echo $(kimaki send --worktree example)",
  'echo "$(kimaki send --worktree example)"',
  "echo `kimaki send --worktree example`",
  "echo ready && kimaki project create example",
  "kimaki send --notify-only --thread 123 --prompt task",
  "kimaki project add /repo",
]) {
  await assert.rejects(hooks["tool.execute.before"]({ tool: "bash" }, { args: { command } }), /ownership guard/, command);
}
for (const command of [
  "homeboy agent-task cook --repo example",
  "kimaki upload-to-discord --session example file.zip",
  "kimaki session archive --session example",
  "kimaki session read example",
  "kimaki project list --json",
  "kimaki send --help",
  "kimaki project add --help",
  "kimaki send --channel 123 --notify-only --prompt 'Build finished'",
  "printf '%s' 'kimaki send --worktree example'",
  "printf '%s' '$(kimaki send --worktree example)'",
  "node -e 'console.log(\"kimaki send --worktree example\")'",
]) {
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command } });
}
console.log("PASS: managed command ownership; bridge operations and quoted data preserved");
