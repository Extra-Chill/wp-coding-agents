// Exercise the actual plugin fetch hook, including persistent cache reuse.
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'claude-identity-'));
const realFetch = globalThis.fetch;
const realNow = Date.now;
const oldCache = process.env.XDG_CACHE_HOME;
const oldOverride = process.env.OPENCODE_ANTHROPIC_USER_AGENT;
const oldKimaki = process.env.KIMAKI;
process.env.XDG_CACHE_HOME = root;
delete process.env.OPENCODE_ANTHROPIC_USER_AGENT;
// The plugin must behave as it does for direct OpenCode runs; this test can
// be executed from a Kimaki-spawned shell where KIMAKI is set.
delete process.env.KIMAKI;
let now = realNow();
Date.now = () => now;
let registryCalls = 0;
let behavior = 'success';
let version = '2.1.999';
let moduleId = 0;
let observedAgent;
globalThis.fetch = async (url, init) => {
  if (String(url).startsWith('https://registry.npmjs.org/')) {
    registryCalls++;
    assert.equal(String(url), 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest');
    assert.deepEqual(init.headers, { accept: 'application/json' });
    assert.equal(init.redirect, 'error');
    assert.ok(init.signal instanceof AbortSignal);
    if (behavior === 'timeout') {
      return new Promise((resolve, reject) => {
        // Keep the event loop alive; AbortSignal.timeout alone is unref'd.
        const guard = setTimeout(() => reject(new Error('timeout was not bounded')), 4000);
        init.signal.addEventListener('abort', () => { clearTimeout(guard); reject(init.signal.reason); }, { once: true });
      });
    }
    if (behavior === 'offline') throw new Error('offline');
    if (behavior === 'http-error') return new Response('{}', { status: 503 });
    return Response.json({ version });
  }
  assert.equal(new Headers(init.headers).get('authorization'), 'Bearer test-access');
  observedAgent = new Headers(init.headers).get('user-agent');
  return Response.json({ content: [] });
};
async function load() {
  const { claudeCodeAuthPlugin } = await import(`../runtimes/opencode/plugins/claude-code-auth.ts?test=${moduleId++}`);
  const plugin = await claudeCodeAuthPlugin({});
  return plugin.auth.loader(async () => ({ type: 'oauth', access: 'test-access', refresh: 'test-refresh', expires: now + 86400000 }), { models: {} });
}
async function request(adapter) {
  await adapter.fetch('https://api.anthropic.com/v1/messages', { method: 'POST', body: JSON.stringify({ model: 'test', messages: [] }) });
  return observedAgent;
}
try {
  let adapter = await load();
  process.env.OPENCODE_ANTHROPIC_USER_AGENT = 'custom-client';
  assert.equal(await request(adapter), 'custom-client');
  assert.equal(registryCalls, 0);
  delete process.env.OPENCODE_ANTHROPIC_USER_AGENT;
  await Promise.all([request(adapter), request(adapter), request(adapter)]);
  assert.equal(observedAgent, 'claude-cli/2.1.999');
  assert.equal(registryCalls, 1, 'concurrent requests share registry lookup');
  await request(adapter);
  adapter = await load();
  assert.equal(await request(adapter), 'claude-cli/2.1.999');
  assert.equal(registryCalls, 1, 'fresh process reuses persistent cache');

  now += 21600001;
  version = '2.2.0';
  assert.equal(await request(adapter), 'claude-cli/2.2.0', 'long-lived session refreshes');
  now += 21600001;
  for (const invalid of ['2.3.0-beta.1', '2.3.0\r\nInjected: yes', '02.3.0', null, '2.3.0\n']) {
    version = invalid;
    assert.equal(await request(adapter), 'claude-cli/2.2.0');
    const count = registryCalls;
    await request(adapter);
    assert.equal(registryCalls, count, 'invalid metadata triggers retry backoff');
    now += 300001;
  }
  behavior = 'timeout';
  const started = performance.now();
  assert.equal(await request(adapter), 'claude-cli/2.2.0');
  assert.ok(performance.now() - started < 3800, 'registry timeout is bounded');
  now += 300001;
  behavior = 'http-error';
  assert.equal(await request(adapter), 'claude-cli/2.2.0');
  now += 300001;
  behavior = 'offline';
  adapter = await load();
  assert.equal(await request(adapter), 'claude-cli/2.2.0', 'offline restart retains last good version');
  await fs.rm(path.join(root, 'opencode'), { recursive: true });
  adapter = await load();
  assert.equal(await request(adapter), 'claude-cli/2.1.280', 'offline bootstrap works');
  now += 300001;
  behavior = 'success';
  version = '2.4.0';
  assert.equal(await request(adapter), 'claude-cli/2.4.0', 'offline fallback recovers');
  // A malformed cache must not suppress discovery indefinitely.
  await fs.writeFile(path.join(root, 'opencode', 'claude-code-version.json'), JSON.stringify({ version: 'invalid', nextCheck: now + 999999999 }));
  adapter = await load();
  assert.equal(await request(adapter), 'claude-cli/2.4.0');
  for (const corrupt of ['null', '{broken', '42', '[]']) {
    await fs.writeFile(path.join(root, 'opencode', 'claude-code-version.json'), corrupt);
    adapter = await load();
    assert.equal(await request(adapter), 'claude-cli/2.4.0', 'corrupt persistent cache recovers');
  }
  // Read-only/unusable persistent storage must not break model requests.
  const blocked = path.join(root, 'file-not-directory');
  await fs.writeFile(blocked, 'x');
  process.env.XDG_CACHE_HOME = blocked;
  adapter = await load();
  assert.equal(await request(adapter), 'claude-cli/2.4.0');
  console.log('PASS: dynamic identity through OpenCode auth hook');
} finally {
  globalThis.fetch = realFetch;
  Date.now = realNow;
  if (oldCache === undefined) delete process.env.XDG_CACHE_HOME; else process.env.XDG_CACHE_HOME = oldCache;
  if (oldOverride === undefined) delete process.env.OPENCODE_ANTHROPIC_USER_AGENT; else process.env.OPENCODE_ANTHROPIC_USER_AGENT = oldOverride;
  if (oldKimaki === undefined) delete process.env.KIMAKI; else process.env.KIMAKI = oldKimaki;
  await fs.rm(root, { recursive: true, force: true });
}
