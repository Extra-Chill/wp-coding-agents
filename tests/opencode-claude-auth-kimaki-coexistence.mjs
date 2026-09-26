// Behavioral coverage for #626: runtimes/opencode/plugins/claude-code-auth.ts
// must coexist with Kimaki's built-in Anthropic auth plugin on one host.
//
// Kimaki's contract (dist/oauth-rotation-shared.js) is the reference:
//   - lock: `${auth.json}.lock` directory, 30s stale, 30s wait
//   - records keep email/accountId; upsert matches on identity
//   - rotation reuses a still-valid access token and refreshes only when
//     expired
//
// Scenarios:
// 1. KIMAKI gate — with KIMAKI set, the plugin registers no auth hook.
// 2. Store normalization — identity fields survive normalization; junk
//    records are dropped.
// 3. Identity preservation — upsert/replace keep email/accountId and dedupe
//    on identity instead of adding duplicates.
// 4. 429 rotation — rotates without refreshing the exhausted account, reuses
//    the next account's valid token, refreshes only an expired one, skips
//    unrefreshable entries, and stops after every account has been tried.
// 5. 401 — refreshes the current credential first and does not rotate.
// 6. Shared lock — concurrent refreshes serialize on the shared lock
//    directory: exactly one token-endpoint call, lock present while the
//    helper runs, lock gone afterwards.
//
// The token endpoint is reached through a spawned `node` helper
// (requestText), so PATH is prepended with a stub `node` that logs refresh
// calls and answers from TOKEN_RULES. API calls go through the in-process
// fetch stub.
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const PLUGIN_URL = new URL('../runtimes/opencode/plugins/claude-code-auth.ts', import.meta.url).href;

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'claude-coexist-'));
const dataHome = path.join(root, 'data');
const binDir = path.join(root, 'bin');
await fs.mkdir(binDir, { recursive: true });

const realEnv = { ...process.env };
const realFetch = globalThis.fetch;
process.env.XDG_DATA_HOME = dataHome;
process.env.OPENCODE_ANTHROPIC_USER_AGENT = 'coexist-test';
delete process.env.KIMAKI;
process.env.PATH = `${binDir}:${process.env.PATH}`;

const AUTH_FILE = path.join(dataHome, 'opencode', 'auth.json');
const STORE_FILE = path.join(dataHome, 'opencode', 'anthropic-oauth-accounts.json');
const LOCK_DIR = `${AUTH_FILE}.lock`;
const TOKEN_CALL_LOG = path.join(root, 'token-calls.log');
process.env.AUTH_FILE = AUTH_FILE;

// Spawned instead of the real node only for the plugin's fetch helper
// (`node -e <script> <payload>`); the payload is the last argv entry.
const FAKE_NODE = `#!${process.execPath}
const fs = require('node:fs');
let refresh = '';
try {
  const payload = JSON.parse(process.argv[process.argv.length - 1]);
  refresh = JSON.parse(payload.body || '{}').refresh_token || '';
} catch {}
fs.appendFileSync(process.env.TOKEN_CALL_LOG, refresh + '\\n');
if (process.env.TOKEN_CHECK_LOCK === '1' && !fs.existsSync(process.env.AUTH_FILE + '.lock')) {
  fs.appendFileSync(process.env.TOKEN_CALL_LOG, 'LOCK-MISSING\\n');
}
const rules = JSON.parse(process.env.TOKEN_RULES || '[]');
const rule = rules.find((candidate) => refresh.includes(candidate.match));
if (rule && rule.delayMs) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, rule.delayMs);
if (!rule || rule.status !== 200) {
  console.error(JSON.stringify({ status: (rule && rule.status) || 400, body: '{"error":"invalid_grant"}' }));
  process.exit(1);
}
process.stdout.write(JSON.stringify({ access_token: rule.access, refresh_token: rule.refresh, expires_in: 3600 }));
`;
await fs.writeFile(path.join(binDir, 'node'), FAKE_NODE, { mode: 0o755 });

const { claudeCodeAuthPlugin, normalizeAccountStore, upsertAccount, replaceAccount, authStateLockPath } = await import(PLUGIN_URL);

const account = (id, extra = {}) => ({
  type: 'oauth',
  refresh: `rt-${id}`,
  access: `acc-${id}`,
  expires: Date.now() + 3600_000,
  addedAt: 1,
  lastUsed: 1,
  ...extra,
});

async function exists(candidate) {
  try { await fs.stat(candidate); return true; } catch { return false; }
}

async function writeState(accounts, activeIndex) {
  await fs.mkdir(path.dirname(AUTH_FILE), { recursive: true });
  await fs.writeFile(STORE_FILE, JSON.stringify({ version: 1, activeIndex, accounts }, null, 2));
  const current = accounts[activeIndex];
  await fs.writeFile(AUTH_FILE, JSON.stringify({ anthropic: { type: 'oauth', refresh: current.refresh, access: current.access, expires: current.expires } }));
}

async function readJson(file) {
  try { return JSON.parse(await fs.readFile(file, 'utf8')); } catch { return null; }
}

async function tokenCalls() {
  const log = await fs.readFile(TOKEN_CALL_LOG, 'utf8').catch(() => '');
  return log.split('\n').filter(Boolean);
}

const getAuth = async () => {
  const data = await readJson(AUTH_FILE);
  return data?.anthropic?.type === 'oauth' ? data.anthropic : { type: 'none' };
};

let apiLog = [];
let apiCalls = 0;
let apiBehavior = () => { throw new Error('apiBehavior not configured'); };
globalThis.fetch = async (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.includes('platform.claude.com')) throw new Error('token endpoint must go through the spawned node helper');
  const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
  apiLog.push(headers.get('authorization'));
  apiCalls++;
  return await apiBehavior();
};

// Behavior keyed on the call counter, not apiLog: the stub logs before the
// behavior runs.
const firstCall429ThenOk = () => (apiCalls <= 1 ? rateLimit429() : ok200());

const rateLimit429 = () => new Response('{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account rate limit."}}', { status: 429 });
const authError401 = () => new Response('{"type":"error","error":{"type":"authentication_error","message":"invalid credentials"}}', { status: 401 });
const ok200 = () => new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });

const loaderFetch = async () => {
  const plugin = await claudeCodeAuthPlugin({});
  const adapter = await plugin.auth.loader(getAuth, { models: {} });
  return adapter.fetch('https://api.anthropic.com/v1/messages', { method: 'POST', body: '{}' });
};

try {
  // 1. KIMAKI gate.
  process.env.KIMAKI = '1';
  const gated = await claudeCodeAuthPlugin({});
  assert.equal(gated.auth, undefined, 'KIMAKI sessions must register no auth hook');
  delete process.env.KIMAKI;

  // 2. Store normalization keeps identity fields and drops junk records.
  const normalized = normalizeAccountStore({
    accounts: [
      account('ok'),
      { type: 'oauth', refresh: 'rt-noadded', access: 'acc-noadded', expires: 1 },
      { type: 'oauth', refresh: 5, access: 'acc-bad', expires: 1, addedAt: 1, lastUsed: 1 },
      account('ident', { email: 'X@Y.Z', accountId: 'acct-ident' }),
    ],
    activeIndex: 9,
  });
  assert.equal(normalized.accounts.length, 2, 'junk records are dropped');
  assert.equal(normalized.accounts[1].email, 'X@Y.Z', 'identity fields survive normalization untouched (case folds at upsert)');
  assert.equal(normalized.accounts[1].accountId, 'acct-ident');
  assert.equal(normalized.activeIndex, 1, 'activeIndex wraps into range');

  // 3. Identity preservation through upsert/replace.
  const store = normalizeAccountStore({
    accounts: [
      account('A', { addedAt: 111 }),
      account('B', { email: 'b@x.com', accountId: 'acct-B', addedAt: 222 }),
      account('C', { email: 'c@x.com', accountId: 'acct-C', addedAt: 333 }),
    ],
    activeIndex: 0,
  });
  upsertAccount(store, { type: 'oauth', refresh: 'rt-C2', access: 'acc-C2', expires: Date.now() + 9, email: 'C@X.com' }, 999);
  assert.equal(store.accounts.length, 3, 're-login to a known identity must not add a duplicate');
  const updatedC = store.accounts.find((entry) => entry.refresh === 'rt-C2');
  assert.equal(updatedC.email, 'c@x.com', 'upsert matches on email despite new tokens');
  assert.equal(updatedC.accountId, 'acct-C', 'upsert preserves accountId');
  assert.equal(updatedC.addedAt, 333, 'upsert preserves addedAt');
  assert.equal(store.activeIndex, store.accounts.indexOf(updatedC), 'upsert activates the matched entry');

  replaceAccount(store, account('A'), { type: 'oauth', refresh: 'rt-A2', access: 'acc-A2', expires: Date.now() + 9 }, 999);
  const replacedA = store.accounts.find((entry) => entry.refresh === 'rt-A2');
  assert.ok(replacedA, 'replace swaps credentials in place');
  assert.equal(replacedA.addedAt, 111, 'replace preserves addedAt');
  assert.equal(replacedA.email, undefined, 'records without identity never gain fabricated ones');
  const untouchedB = store.accounts.find((entry) => entry.refresh === 'rt-B');
  assert.equal(untouchedB.email, 'b@x.com', 'unrelated records keep their identity');
  assert.equal(authStateLockPath(), `${AUTH_FILE}.lock`, 'lock path matches Kimaki');

  // 4a. 429 with a still-valid next account: no refresh calls at all.
  await fs.rm(LOCK_DIR, { recursive: true, force: true }).catch(() => {});
  await writeState([
    account('A', { email: 'a@x.com', accountId: 'acct-A' }),
    account('B', { email: 'b@x.com', accountId: 'acct-B' }),
    account('C', { email: 'c@x.com', accountId: 'acct-C' }),
  ], 0);
  process.env.TOKEN_CALL_LOG = TOKEN_CALL_LOG;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  process.env.TOKEN_RULES = '[]';
  apiLog = [];
  apiCalls = 0;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  apiBehavior = firstCall429ThenOk;
  let response = await loaderFetch();
  assert.equal(response.status, 200, '429 rotates onto a valid next token');
  assert.deepEqual(await tokenCalls(), [], '429 must not spend any refresh token');
  assert.deepEqual(apiLog, ['Bearer acc-A', 'Bearer acc-B'], 'rotation reuses the next account valid access token');
  const authAfter429 = await readJson(AUTH_FILE);
  assert.equal(authAfter429.anthropic.access, 'acc-B', 'rotation activates the next account');
  const storeAfter429 = await readJson(STORE_FILE);
  assert.equal(storeAfter429.accounts[storeAfter429.activeIndex].accountId, 'acct-B');
  assert.equal(storeAfter429.accounts[1].email, 'b@x.com', 'identity survives rotation writes');

  // 4b. Every account exhausted: stop after each has been tried, no loops.
  await writeState([account('A'), account('B')], 0);
  apiLog = [];
  apiCalls = 0;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  apiBehavior = rateLimit429;
  response = await loaderFetch();
  assert.equal(response.status, 429, 'exhausted pool surfaces the upstream error');
  assert.deepEqual(apiLog, ['Bearer acc-A', 'Bearer acc-B'], 'each account is tried exactly once');
  assert.deepEqual(await tokenCalls(), [], 'no refresh is spent on exhausted accounts');

  // 4c. Expired next account: only that account is refreshed.
  await writeState([
    account('A', { email: 'a@x.com', accountId: 'acct-A' }),
    account('B', { email: 'b@x.com', accountId: 'acct-B', expires: Date.now() - 1000 }),
  ], 0);
  apiLog = [];
  apiCalls = 0;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  apiBehavior = firstCall429ThenOk;
  process.env.TOKEN_RULES = JSON.stringify([{ match: 'rt-B', status: 200, access: 'acc-B2', refresh: 'rt-B2' }]);
  response = await loaderFetch();
  assert.equal(response.status, 200);
  assert.deepEqual(await tokenCalls(), ['rt-B'], 'only the rotated account is refreshed, never the exhausted one');
  assert.deepEqual(apiLog, ['Bearer acc-A', 'Bearer acc-B2']);
  const storeAfter4c = await readJson(STORE_FILE);
  const refreshedB = storeAfter4c.accounts.find((entry) => entry.refresh === 'rt-B2');
  assert.equal(refreshedB.email, 'b@x.com', 'rotated refresh preserves identity');
  assert.equal(refreshedB.accountId, 'acct-B');

  // 4d. Unrefreshable next account is skipped; rotation continues.
  await writeState([
    account('A'),
    account('B', { expires: Date.now() - 1000 }),
    account('C'),
  ], 0);
  apiLog = [];
  apiCalls = 0;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  apiBehavior = firstCall429ThenOk;
  process.env.TOKEN_RULES = JSON.stringify([{ match: 'rt-B', status: 400 }]);
  response = await loaderFetch();
  assert.equal(response.status, 200, 'rotation continues past a dead refresh token');
  assert.deepEqual(await tokenCalls(), ['rt-B'], 'the dead account was attempted once, not retried');
  assert.deepEqual(apiLog, ['Bearer acc-A', 'Bearer acc-C']);
  const storeAfter4d = await readJson(STORE_FILE);
  assert.equal(storeAfter4d.accounts[storeAfter4d.activeIndex].access, 'acc-C', 'the working account becomes active');

  // 5. 401: refresh the current credential first, no rotation.
  await writeState([
    account('A', { email: 'a@x.com', accountId: 'acct-A' }),
    account('B'),
  ], 0);
  apiLog = [];
  apiCalls = 0;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  apiBehavior = () => (apiCalls <= 1 ? authError401() : ok200());
  process.env.TOKEN_RULES = JSON.stringify([{ match: 'rt-A', status: 200, access: 'acc-A2', refresh: 'rt-A2' }]);
  response = await loaderFetch();
  assert.equal(response.status, 200);
  assert.deepEqual(await tokenCalls(), ['rt-A'], 'authentication failure refreshes the current account');
  assert.deepEqual(apiLog, ['Bearer acc-A', 'Bearer acc-A2']);
  const authAfter401 = await readJson(AUTH_FILE);
  assert.equal(authAfter401.anthropic.access, 'acc-A2', 'no rotation happened for a refreshable credential');
  const storeAfter401 = await readJson(STORE_FILE);
  assert.equal(storeAfter401.accounts.find((entry) => entry.refresh === 'rt-A2').email, 'a@x.com', '401 refresh preserves identity');

  // 6. Concurrent expired-token requests serialize on the shared lock.
  await writeState([account('A')], 0);
  const expired = { type: 'oauth', refresh: 'rt-A', access: 'acc-A', expires: Date.now() - 1000 };
  await fs.writeFile(AUTH_FILE, JSON.stringify({ anthropic: expired }));
  apiLog = [];
  apiCalls = 0;
  await fs.rm(TOKEN_CALL_LOG, { force: true }).catch(() => {});
  apiBehavior = ok200;
  process.env.TOKEN_CHECK_LOCK = '1';
  process.env.TOKEN_RULES = JSON.stringify([{ match: 'rt-A', status: 200, access: 'acc-A2', refresh: 'rt-A2', delayMs: 150 }]);
  const [first, second] = await Promise.all([loaderFetch(), loaderFetch()]);
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  const calls = await tokenCalls();
  assert.equal(calls.filter((entry) => entry === 'rt-A').length, 1, 'concurrent refreshes share one token-endpoint call');
  assert.ok(!calls.includes('LOCK-MISSING'), 'token endpoint runs inside the shared lock directory');
  assert.deepEqual(apiLog, ['Bearer acc-A2', 'Bearer acc-A2'], 'both requests reuse the refreshed credential');
  assert.ok(!(await exists(LOCK_DIR)), 'shared lock is released after refresh');
  assert.ok(!(await exists(`${AUTH_FILE}.anthropic-refresh.lock`)), 'legacy private lock never appears');

  console.log('PASS: dynamic coexistence behavior (KIMAKI gate, shared lock, identity, rotation)');
} finally {
  globalThis.fetch = realFetch;
  for (const key of Object.keys(process.env)) {
    if (!(key in realEnv)) delete process.env[key];
  }
  Object.assign(process.env, realEnv);
  await fs.rm(root, { recursive: true, force: true });
}
