#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "roadie-session-attribution-"));
const calls = path.join(temp, "calls.jsonl");
const roadie = path.join(temp, "roadie-fixture.mjs");
fs.writeFileSync(
  roadie,
  `#!/usr/bin/env node
import fs from "node:fs";
fs.appendFileSync(process.env.ROADIE_CALL_LOG, JSON.stringify(process.argv.slice(2)) + "\\n");
const session = process.argv.at(-1);
if (session === "missing") process.exit(1);
if (session === "invalid") process.stdout.write("https://example.com/token=secret\\n");
else process.stdout.write("https://discord.com/channels/123456789012345678/" + (session === "two" ? "423456789012345678" : "323456789012345678") + "\\n");
`,
  { mode: 0o755 },
);

process.env.ROADIE_BIN = roadie;
process.env.ROADIE_CALL_LOG = calls;

try {
  const pluginPath = path.join(root, "bridges", "roadie", "plugins", "session-attribution.ts");
  const plugin = (await import(pathToFileURL(pluginPath).href)).default;
  const hooks = await plugin({});

  const first = { env: {} };
  const duplicate = { env: {} };
  await Promise.all([
    hooks["shell.env"]({ cwd: root, sessionID: "one" }, first),
    hooks["shell.env"]({ cwd: root, sessionID: "one" }, duplicate),
  ]);
  assert.equal(readCalls().length, 1, "concurrent lookups should share one process");

  // Homeboy's bridge-neutral session contract (homeboy-extensions#2910).
  assert.equal(first.env.HOMEBOY_SESSION_THREAD_ID, "323456789012345678");
  assert.equal(first.env.HOMEBOY_CALLER_CONTEXT, "roadie:session:one");
  assert.equal(first.env.HOMEBOY_SESSION_SEND_COMMAND, `${roadie} send`);
  assert.equal(duplicate.env.HOMEBOY_SESSION_THREAD_ID, "323456789012345678");
  assert.equal(first.env.DISCORD_BOT_TOKEN, undefined, "the bot token must not reach agent shells");
  assert.equal(first.env.ROADIE_BOT_TOKEN, undefined);

  const second = { env: {} };
  await hooks["shell.env"]({ cwd: root, sessionID: "two" }, second);
  assert.equal(second.env.HOMEBOY_SESSION_THREAD_ID, "423456789012345678", "concurrent sessions keep their own thread");
  assert.equal(second.env.HOMEBOY_CALLER_CONTEXT, "roadie:session:two");
  const forked = { env: { ROADIE_THREAD_ID: "523456789012345678", HOMEBOY_CALLER_CONTEXT: "roadie:session:parent" } };
  await hooks["shell.env"]({ cwd: root, sessionID: "forked" }, forked);
  assert.equal(forked.env.HOMEBOY_CALLER_CONTEXT, "roadie:session:forked");
  const unknown = { env: { HOMEBOY_CALLER_CONTEXT: "roadie:session:parent" } };
  await hooks["shell.env"]({ cwd: root }, unknown);
  assert.equal(unknown.env.HOMEBOY_CALLER_CONTEXT, undefined);

  // Roadie's own shell.env attribution (ROADIE_THREAD_ID) is used as-is.
  const native = { env: { ROADIE_THREAD_ID: "523456789012345678", ROADIE_SESSION_ID: "native-session" } };
  await hooks["shell.env"]({ cwd: root, sessionID: "native" }, native);
  assert.equal(native.env.ROADIE_THREAD_ID, "523456789012345678");
  assert.equal(native.env.HOMEBOY_SESSION_THREAD_ID, "523456789012345678", "native attribution still maps onto the contract");
  assert.equal(native.env.HOMEBOY_SESSION_SEND_COMMAND, `${roadie} send`);

  // Values the host already set win over the bridge mapping.
  const preset = {
    env: {
      ROADIE_THREAD_ID: "623456789012345678",
      HOMEBOY_SESSION_THREAD_ID: "723456789012345678",
      HOMEBOY_SESSION_SEND_URL: "http://127.0.0.1:9/send",
    },
  };
  await hooks["shell.env"]({ cwd: root, sessionID: "preset" }, preset);
  assert.equal(preset.env.HOMEBOY_SESSION_THREAD_ID, "723456789012345678");
  assert.equal(preset.env.HOMEBOY_SESSION_SEND_COMMAND, undefined, "an HTTP sender excludes the command sender");

  // A thread id that is not a snowflake is never exported.
  const bogus = { env: { ROADIE_THREAD_ID: "token=secret" } };
  await hooks["shell.env"]({ cwd: root, sessionID: "bogus" }, bogus);
  assert.equal(bogus.env.HOMEBOY_SESSION_THREAD_ID, undefined);
  assert.equal(bogus.env.HOMEBOY_SESSION_SEND_COMMAND, undefined);
  assert.equal(readCalls().length, 2, "preset attribution should skip the bridge lookup");
  assert.equal(readCalls().length, 2, "native attribution should skip the bridge lookup");

  for (const sessionID of [undefined, "missing", "invalid"]) {
    const output = { env: {} };
    await hooks["shell.env"]({ cwd: root, sessionID }, output);
    assert.equal(output.env.HOMEBOY_SESSION_THREAD_ID, undefined);
    assert.equal(output.env.HOMEBOY_SESSION_SEND_COMMAND, undefined);
  }

  await hooks.event({ event: { type: "session.deleted", properties: { info: { id: "one" } } } });
  await hooks["shell.env"]({ cwd: root, sessionID: "one" }, { env: {} });
  assert.equal(readCalls().filter((args) => args.at(-1) === "one").length, 2, "deletion should evict the cache");

  for (const args of readCalls()) {
    assert.deepEqual(args.slice(0, 2), ["session", "discord-url"]);
    assert.equal(args.length, 3, "session ID must be passed as one positional argv value");
  }
  console.log("PASS: tests/session-attribution.mjs");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}

function readCalls() {
  if (!fs.existsSync(calls)) return [];
  return fs.readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
}
