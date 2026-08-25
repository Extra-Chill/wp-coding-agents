#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "kimaki-session-attribution-"));
const calls = path.join(temp, "calls.jsonl");
const kimaki = path.join(temp, "kimaki-fixture.mjs");
fs.writeFileSync(
  kimaki,
  `#!/usr/bin/env node
import fs from "node:fs";
fs.appendFileSync(process.env.KIMAKI_CALL_LOG, JSON.stringify(process.argv.slice(2)) + "\\n");
const session = process.argv.at(-1);
if (session === "missing") process.exit(1);
if (session === "invalid") process.stdout.write("https://example.com/token=secret\\n");
else process.stdout.write("https://discord.com/channels/123456789012345678/" + (session === "two" ? "423456789012345678" : "323456789012345678") + "\\n");
`,
  { mode: 0o755 },
);

process.env.KIMAKI_BIN = kimaki;
process.env.KIMAKI_CALL_LOG = calls;

try {
  const pluginPath = path.join(root, "bridges", "kimaki", "plugins", "kimaki-session-attribution.ts");
  const plugin = (await import(pathToFileURL(pluginPath).href)).default;
  const hooks = await plugin({});

  const first = { env: {} };
  const duplicate = { env: {} };
  await Promise.all([
    hooks["shell.env"]({ cwd: root, sessionID: "one" }, first),
    hooks["shell.env"]({ cwd: root, sessionID: "one" }, duplicate),
  ]);
  assert.equal(first.env.KIMAKI_THREAD_ID, "323456789012345678");
  assert.equal(first.env.KIMAKI_SESSION_ID, "one");
  assert.equal(duplicate.env.KIMAKI_THREAD_ID, "323456789012345678");
  assert.equal(duplicate.env.KIMAKI_SESSION_ID, "one");
  assert.equal(readCalls().length, 1, "concurrent lookups should share one process");

  const second = { env: {} };
  await hooks["shell.env"]({ cwd: root, sessionID: "two" }, second);
  assert.equal(second.env.KIMAKI_THREAD_ID, "423456789012345678");

  const native = { env: { KIMAKI_THREAD_ID: "523456789012345678", KIMAKI_SESSION_ID: "native-session" } };
  await hooks["shell.env"]({ cwd: root, sessionID: "native" }, native);
  assert.equal(native.env.KIMAKI_THREAD_ID, "523456789012345678");
  assert.equal(native.env.KIMAKI_SESSION_ID, "native-session");
  assert.equal(readCalls().length, 2, "native attribution should skip the bridge lookup");

  for (const sessionID of [undefined, "missing", "invalid"]) {
    const output = { env: {} };
    await hooks["shell.env"]({ cwd: root, sessionID }, output);
    assert.equal(output.env.KIMAKI_THREAD_ID, undefined);
  }

  await hooks.event({ event: { type: "session.deleted", properties: { info: { id: "one" } } } });
  await hooks["shell.env"]({ cwd: root, sessionID: "one" }, { env: {} });
  assert.equal(readCalls().filter((args) => args.at(-1) === "one").length, 2, "deletion should evict the cache");

  for (const args of readCalls()) {
    assert.deepEqual(args.slice(0, 2), ["session", "discord-url"]);
    assert.equal(args.length, 3, "session ID must be passed as one positional argv value");
  }
  console.log("PASS: tests/kimaki-session-attribution.mjs");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}

function readCalls() {
  if (!fs.existsSync(calls)) return [];
  return fs.readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
}
