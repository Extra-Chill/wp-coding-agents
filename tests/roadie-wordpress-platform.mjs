// wordpress-platform.mjs (#771): WordPress as a Roadie chat surface.
//
// Upstream contracts are stubbed, not awaited: Roadie's platform registry
// (roadie#297) is played by a fake `roadie.registerChatPlatform`, the shared
// session runtime by a stub module (WP_CODING_AGENTS_ROADIE_RUNTIME_MODULE),
// and the agents-api claim-bound write abilities (agents-api#585) by a fake
// WP-CLI transport that enforces run_id/claim_token binding. The inbound
// queue connector (#770) is the real scripts/inbound-event-connector.py run
// against a fake wp-control, so ingress is tested end to end:
//
//   queued WP turn  -> assistant parts written through the write abilities
//   question        -> input_required -> claim-chat-run-input round trip
//   cancel          -> session abort + run finalized cancelled
//   identity        -> the existing person filter with platform `wordpress`
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const PHP_NOTICE = 'PHP Warning:  Undefined variable $noise in wp-content/mu-plugins/noise.php on line 3\n'
const SECRET = 'wordpress-platform-test-secret'
const RUNTIME_ID = 'runtime-chat-1'

const root = path.resolve(import.meta.dirname, '..')
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'roadie-wp-platform-'))
const configPath = path.join(temp, 'wordpress-context.json')
const wp = path.join(temp, 'wp.mjs')
const state = path.join(temp, 'state.json')
const calls = path.join(temp, 'calls.jsonl')
const stubPath = path.join(temp, 'runtime-stub.mjs')

// Fake WordPress: plays the agents-api claim-token-bound write abilities
// (agents-api#585) plus datamachine/resolve-chat-person for identity. Writes
// are authorized by the run claim alone: an unknown run_id/claim_token pair is
// refused, exactly like WP_Agent_Chat_Run_Control::verify_run_claim.
fs.writeFileSync(state, JSON.stringify({
  seq: 0,
  messages: [],
  events: [],
  statusLog: [],
  queuedInput: [],
  cancelled: false,
  claims: { run_1: 'tok_1', run_2: 'tok_2', run_3: 'tok_3', run_4: 'tok_4', run_5: 'tok_5' },
  links: { 'wordpress:7': 7, 'discord:ALICE': 7 },
  roles: { 7: 'admin' },
}))
fs.writeFileSync(wp, `import fs from 'node:fs'
const args = process.argv.slice(2)
const code = args[args.indexOf('eval') + 1]
const ability = code.match(/wp_get_ability\\( '([^']+)' \\)/)[1]
const input = JSON.parse(Buffer.from(code.match(/base64_decode\\( '([^']+)'/)[1], 'base64').toString())
fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify({ ability, input, argv: args.filter((arg) => arg !== code) }) + '\\n')
const state = JSON.parse(fs.readFileSync(${JSON.stringify(state)}, 'utf8'))
const save = () => fs.writeFileSync(${JSON.stringify(state)}, JSON.stringify(state))
const out = (value) => { process.stdout.write(${JSON.stringify(PHP_NOTICE)} + JSON.stringify(value)); process.exit(0) }
const fail = (code, message) => out({ error: { code, message } })
if (ability === 'datamachine/resolve-chat-person') {
  const user = state.links[input.platform + ':' + input.actor_id] ?? 0
  if (!user) out({ allowed: false, user_id: 0, role: '', sections: [], reason: 'actor_not_linked' })
  out({ allowed: true, user_id: user, role: state.roles[user] ?? '', reason: '', sections: [] })
}
if (!code.includes("'error' => array(")) { process.stderr.write('claim-bound writes must report refusals as JSON'); process.exit(1) }
if (!input.run_id || state.claims[input.run_id] !== input.claim_token) fail('agents_chat_run_claim_invalid', 'The presented claim token does not match the reserved run.')
if (ability === 'agents/append-chat-run-messages') {
  const ids = input.messages.map((message) => { const id = 'm' + (++state.seq); state.messages.push({ id, run_id: input.run_id, message }); return { id } })
  save(); out({ run_id: input.run_id, messages: ids })
}
if (ability === 'agents/update-chat-run-message') {
  const found = state.messages.find((message) => message.id === input.message_id)
  if (!found) fail('agents_chat_run_message_not_found', input.message_id)
  found.message = input.message
  save(); out({ run_id: input.run_id, message: { id: found.id } })
}
if (ability === 'agents/append-chat-run-events') {
  state.events.push(...input.events.map((event) => ({ run_id: input.run_id, ...event })))
  save(); out({ run_id: input.run_id, appended: input.events.length })
}
if (ability === 'agents/set-chat-run-status') {
  // The canonical status vocabulary is bounded (agents-api#586): there is no
  // input_required run status; anything non-canonical is refused.
  const statuses = ['running', 'cancelling', 'cancelled', 'completed', 'failed', 'runtime_tool_pending', 'approval_required', 'budget_exceeded', 'stalled', 'interrupted']
  if (!statuses.includes(input.status)) fail('agents_chat_run_invalid_status', 'status must be a canonical chat run status other than queued.')
  state.statusLog.push({ run_id: input.run_id, status: input.status })
  save(); out({ run_id: input.run_id, session_id: 'wpca-1', status: input.status, cancelled: state.cancelled })
}
if (ability === 'agents/claim-chat-run-input') {
  // Claimed items are canonical public_queue_item shapes: the answer text is
  // the 'message' string agents/queue-chat-message stored, never 'content'.
  const messages = state.queuedInput
  if (messages.some((item) => typeof item.message !== 'string' || !item.queued_message_id)) fail('agents_chat_run_invalid_queue_item', 'queued items must be canonical public_queue_item shapes')
  state.queuedInput = []
  save(); out({ run_id: input.run_id, session_id: 'wpca-1', status: 'running', messages, count: messages.length })
}
fail('unknown_ability', ability)
`)

// Stub of the shared Roadie runtime seam the platform wires into
// (docs/chat-platforms.md, roadie#297). The plugin and this test import the
// same module instance, so recorded calls are observable directly.
fs.writeFileSync(stubPath, `export const calls = []
export const runtimes = new Map()
export const parentResolver = {}
export function getOrCreateRuntime(input) {
  calls.push(['getOrCreateRuntime', { threadId: input.threadId, channelId: input.channelId, projectDirectory: input.projectDirectory }])
  let rt = runtimes.get(input.threadId)
  if (!rt) {
    rt = { incoming: [], aborted: [] }
    rt.enqueueIncoming = async (message) => { rt.incoming.push(message) }
    rt.abort = async (reason) => { rt.aborted.push(reason) }
    runtimes.set(input.threadId, rt)
  }
  rt.chat = input.chat
  return rt
}
export function disposeRuntime(threadId) { calls.push(['disposeRuntime', threadId]) }
export function markChatPlatformReady(id, ready) { calls.push(['markChatPlatformReady', id, ready]) }
export function setChannelParentResolver(resolver, options) { calls.push(['setChannelParentResolver', options]); parentResolver.fn = resolver }
export const threadSessions = new Map()
export async function getThreadSession(threadId) { return threadSessions.get(threadId) ?? null }
export async function setChannelDirectory(input) { calls.push(['setChannelDirectory', input]) }
export async function readConversationAdmission() { return null }
export async function resolveConversationIntake(input) { calls.push(['intake', { actor: input.actor, threadId: input.threadId, isNewConversation: input.isNewConversation }]); return { outcome: input.text === 'ignore me' ? 'ignore' : 'respond' } }
export async function recordConversationAdmission(input) { calls.push(['admission', { actor: input.actor, starter: input.starter }]) }
export function resolveChannelPolicy() { return undefined }
export function applicationDirectory() { return undefined }
`)

fs.writeFileSync(configPath, JSON.stringify({
  version: 1,
  defaultContext: 'site',
  contexts: { site: { sitePath: '/site', agentSlug: 'franklin', transport: [process.execPath, wp] } },
}))

process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG = configPath
process.env.WP_CODING_AGENTS_ROADIE_RUNTIME_MODULE = stubPath
process.env.WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT = 'http://127.0.0.1:0/wordpress/events'
process.env.WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV = 'TEST_WP_SECRET'
process.env.TEST_WP_SECRET = SECRET

const stub = await import(pathToFileURL(path.resolve(stubPath)).href)
const plugin = await import(pathToFileURL(path.resolve(root, 'bridges/roadie/roadie-plugins/wordpress-platform.mjs')).href)
const context = await import(pathToFileURL(path.resolve(root, 'bridges/roadie/roadie-plugins/wordpress-context.mjs')).href)

const readState = () => JSON.parse(fs.readFileSync(state, 'utf8'))
const setState = (update) => fs.writeFileSync(state, JSON.stringify({ ...readState(), ...update }))
const readCalls = () => fs.readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse)

// register(roadie): the same path Discord and Slack use (roadie#297).
const actions = {}
let definition
plugin.register({
  registerChatPlatform(def) { definition = def },
  addAction(name, fn) { actions[name] = fn },
  addFilter() {},
})
assert.equal(definition?.id, 'wordpress')
// Only the session actions Roadie core actually emits are registered
// (hooks.ts RoadieActions): session_busy/session_aborted do not exist (#777).
assert.deepEqual(Object.keys(actions).sort(), ['session_error', 'session_idle'])

const handle = await definition.start({ platformIds: ['wordpress'], options: {} })
assert(!(handle instanceof Error), String(handle))
const port = handle.address.port
assert(stub.calls.some(([name, id, ready]) => name === 'markChatPlatformReady' && id === 'wordpress' && ready === true))
// Channel policy can walk thread ids back to channel ids.
assert.equal(stub.parentResolver.fn('wordpress:site:wpca-1'), 'wordpress:site')

const sign = (body, timestamp) => 'v0=' + crypto.createHmac('sha256', SECRET).update(`v0:${timestamp}:${body}`).digest('hex')
async function post(event, { mangle = false } = {}) {
  const body = JSON.stringify({ event })
  const timestamp = String(Math.floor(Date.now() / 1000))
  const signature = mangle ? 'v0=' + '0'.repeat(64) : sign(body, timestamp)
  const response = await fetch(`http://127.0.0.1:${port}/wordpress/events`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-wpcodingagents-request-timestamp': timestamp, 'x-wpcodingagents-signature': signature },
    body,
  })
  return { status: response.status, body: await response.json().catch(() => null) }
}
const turnEvent = (runId, claim, overrides = {}) => ({
  source: 'agents-chat',
  external_id: `turn-${runId}`,
  type: 'chat_message',
  conversation_id: overrides.conversation ?? 'wpca-1',
  runtime_id: RUNTIME_ID,
  message: overrides.message ?? 'deploy the fix',
  attributes: { agent: 'franklin', run_id: runId, actor_user_id: '7', runtime_conversation_id: 'rc-1', ...(claim ? { claim_token: claim } : {}) },
  ...(overrides.attachments ? { attachments: overrides.attachments } : {}),
})
const inputEvent = (runId, n, conversation = 'wpca-1') => ({ source: 'agents-chat', external_id: `input-${n}`, type: 'chat_input', conversation_id: conversation, runtime_id: RUNTIME_ID, message: 'input', attributes: { run_id: runId, actor_user_id: '7' } })

try {
  // Ingress refuses anything the connector did not sign.
  const unsigned = await post(turnEvent('run_1', 'tok_1'), { mangle: true })
  assert.equal(unsigned.status, 401)
  assert.equal(stub.runtimes.size, 0)

  // A turn without the run's claim token cannot authorize writes: fail loudly
  // so the connector retries instead of running a turn that can never land.
  const unclaimed = await post(turnEvent('run_1', null))
  assert.equal(unclaimed.status, 422)
  assert.equal(stub.runtimes.size, 0)

  // --- A queued WP turn starts the Roadie session through the shared paths.
  const turned = await post(turnEvent('run_1', 'tok_1'))
  assert.deepEqual([turned.status, turned.body.accepted], [200, true])
  const threadId = 'wordpress:site:wpca-1'
  const rt = stub.runtimes.get(threadId)
  assert(rt, 'turn created the thread session runtime')
  assert.deepEqual(
    { prompt: rt.incoming[0].prompt, userId: rt.incoming[0].userId, actorPlatform: rt.incoming[0].actorPlatform, sourceThreadId: rt.incoming[0].sourceThreadId, mode: rt.incoming[0].mode },
    { prompt: 'deploy the fix', userId: '7', actorPlatform: 'wordpress', sourceThreadId: threadId, mode: 'direct' },
  )
  const intake = stub.calls.find(([name]) => name === 'intake')[1]
  assert.deepEqual(intake.actor, { platform: 'wordpress', id: '7', name: 'wp-user-7' })
  const directory = stub.calls.find(([name]) => name === 'getOrCreateRuntime')[1]
  assert.deepEqual(directory, { threadId, channelId: 'wordpress:site', projectDirectory: '/site' })

  // --- Assistant output lands in the WP run through the write abilities.
  const chat = rt.chat
  assert.equal(chat.platform, 'wordpress')
  const part = await chat.sendPart('Working on it')
  const notice = await chat.sendNotice('Deploying')
  const message = await chat.sendMessage('| a | b |')
  const appended = readState().messages
  assert.deepEqual(appended.map((entry) => [entry.id, entry.run_id, entry.message.role, entry.message.type, entry.message.content]), [
    [part.id, 'run_1', 'assistant', 'text', 'Working on it'],
    [notice.id, 'run_1', 'assistant', 'notice', 'Deploying'],
    [message.id, 'run_1', 'assistant', 'text', '| a | b |'],
  ])
  const appendCall = readCalls().find((entry) => entry.ability === 'agents/append-chat-run-messages')
  assert.deepEqual([appendCall.input.run_id, appendCall.input.claim_token, appendCall.argv], ['run_1', 'tok_1', ['--path=/site', 'eval', '--allow-root']])
  assert.equal(await chat.editMessageText(part.id, 'Streamed and edited'), undefined)
  assert.equal(readState().messages[0].message.content, 'Streamed and edited')
  assert.equal(await chat.readMessageText(part.id), 'Streamed and edited')
  assert.equal(await chat.setPendingMarker(part.id, true), undefined)
  await chat.rename('Deploy thread')
  assert.equal(chat.name, 'Deploy thread')
  const events = readState().events
  assert.deepEqual(events.map((entry) => entry.type), ['pending_marker', 'rename'])
  assert.deepEqual(events[0].metadata, { message_id: part.id, on: true })
  const recent = await chat.readRecentMessages(10)
  assert.deepEqual([recent[0].author, recent[0].fromBot, recent[0].text], ['7', false, 'deploy the fix'])
  assert.deepEqual([recent[1].fromBot, recent[1].text], [true, 'Streamed and edited'])

  // --- A question round-trips: input_required message out (the run status
  // stays canonical `running` while waiting), claim-chat-run-input back.
  await chat.interactions.question({ sessionId: 's1', directory: '/site', requestId: 'q1', input: { question: 'Which color?', options: ['red', 'blue'] } })
  assert.equal(chat.interactions.hasQuestion(), true)
  const question = readState().messages.at(-1)
  assert.deepEqual([question.message.type, question.message.content, question.message.payload.kind, question.message.payload.request_id], ['input_required', 'Which color?', 'question', 'q1'])
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_1', status: 'running' })
  setState({ queuedInput: [{ queued_message_id: 'queued_u1', session_id: 'wpca-1', run_id: 'run_1', agent: 'franklin', message: 'blue', attachments: [], client_context: {}, created_at: '2026-01-01T00:00:00+00:00' }] })
  const answered = await post(inputEvent('run_1', 1))
  assert.deepEqual([answered.status, answered.body.answered], [200, true])
  assert(readCalls().some((entry) => entry.ability === 'agents/claim-chat-run-input' && entry.input.run_id === 'run_1' && entry.input.claim_token === 'tok_1'))
  assert.equal(chat.interactions.hasQuestion(), false)
  assert.equal(rt.incoming.at(-1).prompt, 'blue')
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_1', status: 'running' })

  // --- An upload request resolves with the answer's attachment URLs.
  const uploadPromise = chat.interactions.upload({ sessionId: 's1', directory: '/site', prompt: 'Attach the logs', maxFiles: 2 })
  await new Promise((resolve) => setTimeout(resolve, 50))
  setState({ queuedInput: [{ queued_message_id: 'queued_u2', session_id: 'wpca-1', run_id: 'run_1', agent: 'franklin', message: '', attachments: [{ type: 'file', url: 'https://example.com/debug.log' }], client_context: {}, created_at: '2026-01-01T00:00:01+00:00' }] })
  await post(inputEvent('run_1', 2))
  assert.deepEqual(await uploadPromise, ['https://example.com/debug.log'])

  // --- Permission requests become canonical approval_required.
  const permission = await chat.interactions.permission({ permission: { requestId: 'p1', title: 'Run composer install?' }, directory: '/site' })
  const approval = readState().messages.at(-1)
  assert.deepEqual([approval.message.type, approval.message.payload.kind, approval.id], ['approval_required', 'permission', permission.messageId])
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_1', status: 'approval_required' })
  assert.equal(chat.interactions.addPermissionRequest({ contextHash: permission.contextHash, requestId: 'p2' }), true)
  chat.interactions.clearPermission(permission.contextHash)
  assert.equal(chat.interactions.hasPending(), false)

  // --- An answer that arrives as a new agents/chat turn supersedes the
  // waiting run explicitly: linking event + terminal status for run_1, then
  // the new run adopts the session and delivers the answer (#778).
  await chat.interactions.question({ sessionId: 's1', directory: '/site', requestId: 'q2', input: { question: 'Deploy to production?' } })
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_1', status: 'running' })
  const answeredTurn = await post(turnEvent('run_4', 'tok_4', { message: 'yes, ship it' }))
  assert.deepEqual([answeredTurn.status, answeredTurn.body.answered], [200, true])
  assert.equal(chat.interactions.hasQuestion(), false)
  assert.equal(rt.incoming.at(-1).prompt, 'yes, ship it')
  const superseded = readState().events.find((event) => event.type === 'run_superseded')
  assert.deepEqual([superseded.run_id, superseded.metadata.next_run_id], ['run_1', 'run_4'], 'the stranded run is linked to its successor')
  assert(readState().statusLog.some((entry) => entry.run_id === 'run_1' && entry.status === 'completed'), 'the superseded run ended in a terminal status')
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_4', status: 'running' })

  // --- Run status follows the thread's *main* session only (#777): a
  // delegated child session (subagent) fires session_idle with
  // parentSessionId set and the same threadId; it must not finalize the run.
  const statusWriteCount = () => readState().statusLog.length
  const before = statusWriteCount()
  await actions.session_idle({ threadId, sessionId: 'child-1', parentSessionId: 'main-1' })
  assert.equal(statusWriteCount(), before, 'a child session going idle wrote no run status')
  // Once the thread's main session is known, a stale session's idle is ignored.
  stub.threadSessions.set(threadId, 'main-1')
  await actions.session_idle({ threadId, sessionId: 'stale-1' })
  assert.equal(statusWriteCount(), before, 'a stale session idle wrote no run status')
  // The main session going idle completes the run.
  await actions.session_idle({ threadId, sessionId: 'main-1' })
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_4', status: 'completed' })

  // --- The real inbound-event-connector delivers the next queued turn.
  const bindir = path.join(temp, 'bin')
  fs.mkdirSync(bindir)
  const connector = path.join(bindir, 'inbound-event-connector')
  fs.copyFileSync(path.join(root, 'scripts/inbound-event-connector.py'), connector)
  fs.chmodSync(connector, 0o755)
  const controlState = path.join(temp, 'control-state.json')
  const controlLog = path.join(temp, 'control-log.txt')
  const control = path.join(bindir, 'wp-control')
  fs.writeFileSync(control, '#!/usr/bin/env python3\nimport os,sys\nopen(os.environ["CONTROL_LOG"],"a").write(" ".join(sys.argv[1:])+"\\n")\nif "poll" in sys.argv: print(open(os.environ["CONTROL_STATE"]).read())\n')
  fs.chmodSync(control, 0o755)
  fs.writeFileSync(controlState, JSON.stringify({ status: 'claimed', claim: { id: 21, lease_token: 'lease-21', event: turnEvent('run_2', 'tok_2', { message: 'and run the tests' }) } }))
  // Async: the connector posts back into this process's ingress server, so
  // the event loop must stay free to answer while the connector waits.
  await new Promise((resolve, reject) => {
    execFile('python3', [connector, '--once'], {
      env: {
        ...process.env,
        CONTROL_STATE: controlState,
        CONTROL_LOG: controlLog,
        WP_CODING_AGENTS_RUNTIME_ID: RUNTIME_ID,
        WP_CODING_AGENTS_INBOUND_WORDPRESS_ENABLED: '1',
        WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT: `http://127.0.0.1:${port}/wordpress/events`,
      },
    }, (error) => (error ? reject(error) : resolve()))
  })
  assert(fs.readFileSync(controlLog, 'utf8').includes('ack 21 --lease-token=lease-21'), 'connector acked after the platform accepted the turn')
  assert.equal(rt.incoming.at(-1).prompt, 'and run the tests')
  assert.equal(readState().events.filter((event) => event.type === 'run_superseded').length, 1, 'an already-finalized run is not superseded again')

  // --- agents/cancel-chat-run aborts: the queued chat_cancel stops the
  // session and finalizes the run as cancelled.
  const cancelled = await post({ source: 'agents-chat', external_id: 'cancel-run_2', type: 'chat_cancel', conversation_id: 'wpca-1', runtime_id: RUNTIME_ID, message: 'cancel', attributes: { run_id: 'run_2', actor_user_id: '7', runtime_conversation_id: 'rc-1' } })
  assert.deepEqual([cancelled.status, cancelled.body.cancelled], [200, true])
  assert.equal(rt.aborted.length, 1)
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_2', status: 'cancelled' })

  // --- Every status heartbeat doubles as cancellation observation: a
  // committed WP-side cancel aborts the session on the next status write.
  await post(turnEvent('run_3', 'tok_3', { message: 'one more thing' }))
  setState({ cancelled: true })
  await actions.session_idle({ threadId, sessionId: 'main-1' })
  assert.equal(rt.aborted.length, 2, 'the cancelled echo aborted the session')
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_3', status: 'cancelled' })
  setState({ cancelled: false })

  // --- A Roadie-side abort finalizes the run as cancelled (#777): Roadie's
  // abortActiveRunInternal calls interactions.cancelQuestion() (the only
  // abort-time signal the platform receives; roadie#300) and the abort then
  // settles as a plain session_idle.
  await post(turnEvent('run_4', 'tok_4', { message: 'take it back' }))
  await chat.interactions.cancelQuestion()
  await actions.session_idle({ threadId, sessionId: 'main-1' })
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_4', status: 'cancelled' })

  // The abort observation does not leak into the next run: a fresh turn's
  // main-session idle completes normally.
  await post(turnEvent('run_5', 'tok_5', { message: 'try again' }))
  await actions.session_idle({ threadId, sessionId: 'main-1' })
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_5', status: 'completed' })

  // --- Writes are claim-bound: an unknown run/claim pair is refused by WP.
  await post(turnEvent('run_bad', 'bad-token', { conversation: 'wpca-2' }))
  const badChat = stub.runtimes.get('wordpress:site:wpca-2').chat
  const refused = await badChat.sendNotice('should not land')
  assert(refused instanceof Error && refused.message.includes('agents_chat_run_claim_invalid'))
  assert(!readState().messages.some((entry) => entry.run_id === 'run_bad'))

  // --- A turn the intake ignores still ends in a terminal status, and a
  // later queued answer with nowhere to go (no pending interaction, no
  // session runtime) is left durably queued instead of claimed-and-dropped.
  const ignoredTurn = await post(turnEvent('run_5', 'tok_5', { conversation: 'wpca-3', message: 'ignore me' }))
  assert.deepEqual([ignoredTurn.status, ignoredTurn.body.ignored], [200, true])
  assert.deepEqual(readState().statusLog.at(-1), { run_id: 'run_5', status: 'completed' }, 'the ignored turn finalized its run')
  assert.equal(stub.runtimes.has('wordpress:site:wpca-3'), false, 'no session runtime was created for the ignored turn')
  const strayItem = { queued_message_id: 'queued_u9', session_id: 'wpca-3', run_id: 'run_5', agent: 'franklin', message: 'stray answer', attachments: [], client_context: {}, created_at: '2026-01-01T00:00:02+00:00' }
  setState({ queuedInput: [strayItem] })
  const strayInput = await post(inputEvent('run_5', 9, 'wpca-3'))
  assert.deepEqual([strayInput.status, strayInput.body.ignored], [200, true])
  assert(!readCalls().some((entry) => entry.ability === 'agents/claim-chat-run-input' && entry.input.run_id === 'run_5'), 'nothing drained the answer it could not deliver')
  assert.deepEqual(readState().queuedInput, [strayItem], 'the answer stays durably queued canonical-side')
  setState({ queuedInput: [] })

  // --- Identity: the actor goes through the existing person filter with
  // platform `wordpress`, so seats and permissions match Discord.
  const filters = {}
  context.register({ addFilter(name, fn) { filters[name] = fn } })
  const person = await filters.person(null, { actor: { platform: 'wordpress', id: '7' }, context: { channelId: 'C1' } })
  assert.deepEqual([person.allowed, person.personId, [...person.capabilities]], [true, 'wordpress:/site:7', ['sessions', 'shell', 'admin']])
  const unlinked = await filters.person(null, { actor: { platform: 'wordpress', id: '99' }, context: { channelId: 'C1' } })
  assert.equal(unlinked.allowed, false)

  // --- Every status write the plugin made used the canonical vocabulary.
  const canonical = ['running', 'cancelling', 'cancelled', 'completed', 'failed', 'runtime_tool_pending', 'approval_required', 'budget_exceeded', 'stalled', 'interrupted']
  const statusWrites = readCalls().filter((entry) => entry.ability === 'agents/set-chat-run-status')
  assert(statusWrites.length > 0 && statusWrites.every((entry) => canonical.includes(entry.input.status)), 'only canonical run statuses are ever written')

  // --- Shutdown disposes runtimes and reports the platform not ready.
  await handle.stop()
  assert(stub.calls.some(([name, id, ready]) => name === 'markChatPlatformReady' && id === 'wordpress' && ready === false))
  assert(stub.calls.some(([name, id]) => name === 'disposeRuntime' && id === threadId))

  console.log('PASS: wordpress platform registers, writes through claim-bound abilities, round-trips questions on a single run, supersedes stranded runs on turn takeover, finalizes runs from the main session only, cancels on Roadie-side aborts, and resolves identity through the person filter')
} finally {
  fs.rmSync(temp, { recursive: true, force: true })
}
