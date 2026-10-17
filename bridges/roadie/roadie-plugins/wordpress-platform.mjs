// WordPress as a Roadie chat surface (#771). This plugin registers a
// `wordpress` chat platform through Roadie's platform registry (roadie#297):
// WordPress conversation sessions (agents-api) are the thread, and everything
// the session runtime says lands in the WP run through the canonical
// claim-token-bound write abilities (Automattic/agents-api#585):
//
//   agents/append-chat-run-messages   sendPart / sendMessage / sendNotice,
//                                     input_required and approval_required
//   agents/update-chat-run-message    editMessageText (streamed text edits)
//   agents/append-chat-run-events     setPendingMarker, rename, lifecycle
//   agents/set-chat-run-status        run status follows session state; the
//                                     response carries `cancelled`, so every
//                                     heartbeat doubles as abort observation
//   agents/claim-chat-run-input       drains queued answers to a question
//
// Ingress is the inbound queue (#770): `WpCodingAgents_Runtime_Chat` durably
// queues each accepted turn (source `agents-chat`), the host's
// inbound-event-connector claims it and delivers it to this plugin's loopback
// HTTP endpoint with an HMAC signature. The event carries the WP session id
// as conversation_id, the dispatcher-assigned run_id and the run's
// claim_token; writes are authorized by that claim alone.
//
// Identity stays with the existing person filter: incoming turns are enqueued
// with `actor.platform = 'wordpress'` and `actor.id` = the authenticated WP
// user id from the event, so wordpress-context.mjs resolves the person through
// `datamachine/resolve-chat-person` exactly like Discord speakers.
import fs from 'node:fs'
import path from 'node:path'
import http from 'node:http'
import crypto from 'node:crypto'
import { execFile } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  abilityPhp,
  describeLookupFailure,
  lookupTimeoutMs,
  parseResolverStdout,
  resolveBinding,
} from './wordpress-context.mjs'

export const PLATFORM_ID = 'wordpress'
export const EVENT_SOURCE = 'agents-chat'

export const WRITE_ABILITIES = Object.freeze({
  appendMessages: 'agents/append-chat-run-messages',
  updateMessage: 'agents/update-chat-run-message',
  appendEvents: 'agents/append-chat-run-events',
  setStatus: 'agents/set-chat-run-status',
  claimInput: 'agents/claim-chat-run-input',
})

// Roadie session-lifecycle actions mapped onto canonical run statuses. These
// are the only session actions Roadie core emits (hooks.ts `RoadieActions`);
// there is no busy or aborted action. The run was left open (`running`) by
// the pending handler return, so no busy signal is needed, and a
// Roadie-initiated abort is observed through `interactions.cancelQuestion()`
// (see createWordPressChatThread) and turns the settling idle into
// `cancelled`. A backend-side abort (`MessageAbortedError` that Roadie did
// not start) emits no action at all: Extra-Chill/roadie#300 tracks the
// missing generic `session_aborted` action.
export const SESSION_STATUS = Object.freeze({
  session_idle: 'completed',
  session_error: 'failed',
})

const DEFAULT_ENDPOINT = 'http://127.0.0.1:3712/wordpress/events'
const MAX_BODY_BYTES = 64 * 1024
const SIGNATURE_TOLERANCE_SECONDS = 300

// ---------------------------------------------------------------------------
// Config: the same wordpress-context.json that binds Roadie contexts to a
// site and agent also tells this platform which context serves a turn.
// ---------------------------------------------------------------------------

export function loadConfig(configPath) {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  if (config.version !== 1 || !config.contexts) throw new Error('Use version 1 with contexts in wordpress-context.json')
  return config
}

/** The context whose agentSlug matches the turn's agent attribute. */
export function bindingForAgent(config, agentSlug) {
  if (typeof agentSlug !== 'string' || !agentSlug) return null
  for (const contextKey of Object.keys(config.contexts)) {
    const binding = resolveBinding(config, { contextId: contextKey })
    if (binding && binding.agentSlug === agentSlug) return { contextKey, binding }
  }
  return null
}

// Thread ids are namespaced (`wordpress:<context>:<wp-session-id>`) so shared
// Roadie tables never collide with other platforms in the same process.
export const channelIdFor = (contextKey) => `${PLATFORM_ID}:${contextKey}`
export const threadIdFor = (contextKey, conversationId) => `${channelIdFor(contextKey)}:${conversationId}`

// ---------------------------------------------------------------------------
// Ingress contract shared with scripts/inbound-event-connector.py: a loopback
// endpoint, an HMAC-SHA256 signature over `v0:<timestamp>:<body>`.
// ---------------------------------------------------------------------------

export function ingressConfig(env = process.env) {
  const endpoint = env.WP_CODING_AGENTS_INBOUND_WORDPRESS_ENDPOINT ?? DEFAULT_ENDPOINT
  let url
  try { url = new URL(endpoint) } catch { return new Error(`WordPress ingress endpoint is not a URL: ${endpoint}`) }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  if (!['http:', 'https:'].includes(url.protocol) || !loopback || url.username || url.password || !url.port) {
    return new Error('WordPress ingress endpoint must be an http(s) loopback URL with an explicit port')
  }
  const secretName = env.WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV ?? ''
  if (!/^[A-Z_][A-Z0-9_]*$/.test(secretName) || !env[secretName]) {
    return new Error('WordPress ingress signing secret environment variable is not configured (WP_CODING_AGENTS_INBOUND_WORDPRESS_SIGNING_SECRET_ENV)')
  }
  return { url, secret: env[secretName] }
}

export function verifySignature({ secret, timestamp, signature, body, now = Date.now() }) {
  if (typeof timestamp !== 'string' || !/^\d{1,20}$/.test(timestamp)) return false
  if (Math.abs(now / 1000 - Number(timestamp)) > SIGNATURE_TOLERANCE_SECONDS) return false
  const expected = 'v0=' + crypto.createHmac('sha256', secret).update(`v0:${timestamp}:`).update(body).digest('hex')
  const presented = Buffer.from(String(signature ?? ''))
  const wanted = Buffer.from(expected)
  return presented.length === wanted.length && crypto.timingSafeEqual(presented, wanted)
}

const EVENT_TYPES = new Set(['chat_message', 'chat_input', 'chat_cancel'])

/** Normalize one queued event; an Error names what is malformed. */
export function validateEvent(event) {
  if (!event || typeof event !== 'object') return new Error('Event is not an object')
  if (event.source !== EVENT_SOURCE) return new Error(`Unsupported event source: ${String(event.source)}`)
  if (!EVENT_TYPES.has(event.type)) return new Error(`Unsupported event type: ${String(event.type)}`)
  for (const key of ['conversation_id', 'message']) {
    if (typeof event[key] !== 'string' || !event[key]) return new Error(`Event is missing ${key}`)
  }
  const attributes = event.attributes
  if (!attributes || typeof attributes !== 'object') return new Error('Event is missing attributes')
  if (typeof attributes.run_id !== 'string' || !attributes.run_id) return new Error('Event is missing attributes.run_id')
  if (typeof attributes.actor_user_id !== 'string' || !/^[1-9][0-9]{0,18}$/.test(attributes.actor_user_id)) {
    return new Error('Event is missing an authenticated actor_user_id')
  }
  const attachments = Array.isArray(event.attachments) ? event.attachments.filter((entry) => entry && typeof entry === 'object') : []
  return { type: event.type, conversationId: event.conversation_id, message: event.message, attributes, attachments }
}

// ---------------------------------------------------------------------------
// Write path: every operation is one `agents/*` ability call bound to the
// run claim, executed inside WordPress through the context's transport.
// ---------------------------------------------------------------------------

function runAbility(binding, ability, input) {
  const [command, ...prefix] = binding.transport
  return new Promise((resolve, reject) => {
    const timeout = lookupTimeoutMs(binding)
    execFile(command, [...prefix, `--path=${binding.sitePath}`, 'eval', abilityPhp(ability, input, { errorsAsJson: true }), '--allow-root'], { timeout, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) { reject(new Error(`WordPress chat run write failed: ${describeLookupFailure(error, stderr, timeout)}`, { cause: error })); return }
      try { resolve(parseResolverStdout(stdout)) } catch (cause) { reject(new Error(cause instanceof Error ? cause.message : 'WordPress chat run write returned invalid JSON', { cause })) }
    })
  })
}

export function createRunWriter(binding) {
  const call = async (ability, run, extra = {}) => {
    if (!run || typeof run.runId !== 'string' || !run.runId || typeof run.claimToken !== 'string' || !run.claimToken) {
      throw new Error('No claimed run to write through; the turn event carried no claim_token')
    }
    const result = await runAbility(binding, ability, { run_id: run.runId, claim_token: run.claimToken, ...extra })
    if (result.error) throw new Error(`${ability} refused: ${result.error.code ?? 'unknown'}`)
    return result
  }
  return {
    async append(run, messages) {
      const result = await call(WRITE_ABILITIES.appendMessages, run, { messages })
      const ids = Array.isArray(result.messages) ? result.messages.map((message) => message?.id).filter((id) => typeof id === 'string' && id) : []
      if (ids.length !== messages.length) throw new Error(`${WRITE_ABILITIES.appendMessages} returned no stable message ids`)
      return ids
    },
    update: (run, messageId, message) => call(WRITE_ABILITIES.updateMessage, run, { message_id: messageId, message }),
    events: (run, events) => call(WRITE_ABILITIES.appendEvents, run, { events }),
    status: (run, status) => call(WRITE_ABILITIES.setStatus, run, { status }),
    claimInput: (run) => call(WRITE_ABILITIES.claimInput, run),
  }
}

// ---------------------------------------------------------------------------
// ChatThread (roadie#297 cli/src/chat-platform/types.ts) over one WP session.
// ---------------------------------------------------------------------------

const envelope = (type, content, payload) => ({ role: 'assistant', type, content, ...(payload ? { payload } : {}) })
const asError = (error) => (error instanceof Error ? error : new Error(String(error)))

// agents/set-chat-run-status accepts only the canonical chat run vocabulary
// (agents-api#586); these are the terminal members. `input_required` is a
// message *type*, never a run status: a run waiting on an answer stays
// `running` until the same run completes (#778).
const TERMINAL_STATUSES = new Set(['completed', 'failed', 'cancelled'])

export function createWordPressChatThread({ contextKey, conversationId, writer }) {
  const history = [] // ChatHistoryMessage shape, oldest first
  let currentRun = null
  const finalized = new Set() // run ids that reached a terminal status
  let name = conversationId
  let abortRequested = null
  let abortObserved = false // Roadie-initiated abort seen since the run began
  let pendingQuestion = null // { kind, requestId?, messageId, maxFiles?, resolveUpload? }
  const permissions = new Map() // contextHash -> Set(requestId)

  const requireRun = () => {
    if (!currentRun) throw new Error(`No active run for WordPress conversation ${conversationId}`)
    return currentRun
  }

  // The set-chat-run-status response always carries `cancelled`, so every
  // status write doubles as cancellation observation (agents-api#585).
  const heartbeat = async (status) => {
    const run = requireRun()
    const result = await writer.status(run, status)
    if (TERMINAL_STATUSES.has(status) || TERMINAL_STATUSES.has(result?.status)) finalized.add(run.runId)
    if (result?.cancelled === true && abortRequested) await abortRequested('cancelled')
    return result
  }

  const appendOne = async (message, text) => {
    const [id] = await writer.append(requireRun(), [message])
    history.push({ id, author: 'wordpress-runtime', fromBot: true, text })
    return { id }
  }

  const interactions = {
    // Permission → canonical approval_required message + suspended status.
    async permission({ permission }) {
      const requestId = String(permission?.requestId ?? permission?.id ?? 'permission')
      const contextHash = crypto.createHash('sha256').update(`${conversationId}:${requestId}`).digest('hex').slice(0, 16)
      const text = typeof permission?.title === 'string' && permission.title ? permission.title : 'The agent needs permission to continue.'
      const { id } = await appendOne(envelope('approval_required', text, { kind: 'permission', request_id: requestId, permission }), text)
      permissions.set(contextHash, new Set([requestId]))
      await heartbeat('approval_required')
      return { messageId: id, contextHash }
    },
    addPermissionRequest({ contextHash, requestId }) {
      const existing = permissions.get(contextHash)
      if (!existing) return false
      existing.add(requestId)
      return true
    },
    clearPermission(contextHash) { permissions.delete(contextHash) },
    // Question → canonical input_required *message*; the run status stays
    // `running` (there is no input_required run status in the agents-api
    // vocabulary) and the heartbeat doubles as cancellation observation. The
    // answer arrives through agents/queue-chat-message → chat_input and is
    // drained with agents/claim-chat-run-input for this same run (#778).
    async question({ requestId, input }) {
      const text = typeof input?.question === 'string' && input.question ? input.question : 'The agent needs an answer to continue.'
      const { id } = await appendOne(envelope('input_required', text, { kind: 'question', request_id: requestId, question: input }), text)
      pendingQuestion = { kind: 'question', requestId, messageId: id }
      await heartbeat('running')
    },
    async actions({ buttons }) {
      const labels = (Array.isArray(buttons) ? buttons : []).map((button) => button?.label).filter((label) => typeof label === 'string' && label)
      const text = labels.length ? labels.join(' | ') : 'Choose an action to continue.'
      const { id } = await appendOne(envelope('input_required', text, { kind: 'actions', buttons }), text)
      pendingQuestion = { kind: 'actions', messageId: id }
      await heartbeat('running')
    },
    // Upload → file request; resolves with the attachment URLs of the answer.
    async upload({ prompt, maxFiles }) {
      const text = typeof prompt === 'string' && prompt ? prompt : 'Attach the requested files.'
      const { id } = await appendOne(envelope('input_required', text, { kind: 'file_request', prompt: text, max_files: maxFiles }), text)
      await heartbeat('running')
      return new Promise((resolve) => { pendingQuestion = { kind: 'upload', messageId: id, maxFiles, resolveUpload: resolve } })
    },
    hasQuestion: () => pendingQuestion !== null,
    hasPending: () => pendingQuestion !== null || permissions.size > 0,
    async cancelQuestion() {
      // Roadie core calls cancelQuestion exactly once, in
      // abortActiveRunInternal (thread-session-runtime.ts), on every
      // Roadie-initiated abort — the only signal the platform receives at
      // abort time (no session_aborted action exists; roadie#300). Remember
      // it so the settling session_idle finalizes the run as cancelled
      // rather than completed (#777).
      abortObserved = true
      if (!pendingQuestion) return
      const cancelled = pendingQuestion
      pendingQuestion = null
      if (cancelled.resolveUpload) cancelled.resolveUpload([])
      if (currentRun) await writer.events(currentRun, [{ type: 'question_cancelled', metadata: { message_id: cancelled.messageId } }]).catch(() => {})
    },
    dispose() {
      if (pendingQuestion?.resolveUpload) pendingQuestion.resolveUpload([])
      pendingQuestion = null
      permissions.clear()
    },
  }

  const thread = {
    platform: PLATFORM_ID,
    interactions,
    capabilities: { rename: true, typing: false },
    id: threadIdFor(contextKey, conversationId),
    get name() { return name },
    parentId: channelIdFor(contextKey),
    spaceId: contextKey,
    createdAt: Date.now(),
    botUserId: 'wordpress-runtime',
    async footerMentionUserId() { return undefined },
    setReplyAnchor() {},
    async sendNotice(content) {
      try { return await appendOne(envelope('notice', content), content) } catch (error) { return asError(error) }
    },
    async sendMessage(content) { return appendOne(envelope('text', content), content) },
    async sendPart(content) { return appendOne(envelope('text', content), content) },
    async readMessageText(messageId) {
      const found = history.find((message) => message.id === messageId)
      return found ? found.text : new Error(`No message ${messageId} in ${threadIdFor(contextKey, conversationId)}`)
    },
    async readRecentMessages(limit) { return history.slice(-Math.max(1, limit)) },
    async editMessageText(messageId, content) {
      try {
        await writer.update(requireRun(), messageId, envelope('text', content))
        const found = history.find((message) => message.id === messageId)
        if (found) found.text = content
      } catch (error) { return asError(error) }
    },
    async setPendingMarker(messageId, on) {
      try { await writer.events(requireRun(), [{ type: 'pending_marker', metadata: { message_id: messageId, on: Boolean(on) } }]) } catch (error) { return asError(error) }
    },
    async sendTyping() {},
    async rename(next) {
      await writer.events(requireRun(), [{ type: 'rename', message: next }])
      name = next
    },
    async syncTitle(title) {
      try { await thread.rename(title) } catch (error) { return asError(error) }
    },
    async channelTopic() { return undefined },
  }

  return {
    thread,
    heartbeat,
    /**
     * Adopt a newly claimed run. An open previous run is superseded
     * explicitly — a linking `run_superseded` event plus a terminal status —
     * so no run is ever stranded waiting when a new turn takes over (#778).
     */
    async adoptRun(run) {
      const previous = currentRun
      if (previous && previous.runId !== run.runId && !finalized.has(previous.runId)) {
        await writer.events(previous, [{ type: 'run_superseded', metadata: { next_run_id: run.runId } }]).catch(() => {})
        await writer.status(previous, 'completed').catch(() => {})
        finalized.add(previous.runId)
      }
      currentRun = run
      abortObserved = false
    },
    markFinalized(runId) { finalized.add(runId) },
    isFinalized: (runId) => finalized.has(runId),
    currentRun: () => currentRun,
    /** True once if Roadie aborted since the current run began. */
    consumeAbortObservation() { const seen = abortObserved; abortObserved = false; return seen },
    onAbortRequested(fn) { abortRequested = fn },
    recordIncoming(text, userId) { history.push({ id: `wp-user-${history.length + 1}`, author: String(userId), fromBot: false, text }) },
    /** Deliver drained answers to the pending interaction, if any. */
    async deliverAnswers(answers) {
      if (!pendingQuestion || !answers.length) return null
      const pending = pendingQuestion
      pendingQuestion = null
      if (pending.kind === 'upload') {
        const files = answers
          .flatMap((answer) => (Array.isArray(answer.attachments) ? answer.attachments : []))
          .map((attachment) => attachment?.url)
          .filter((url) => typeof url === 'string' && url)
          .slice(0, Math.max(1, Number(pending.maxFiles) || 1))
        pending.resolveUpload(files)
        if (currentRun) await heartbeat('running').catch(() => {})
        return { kind: 'upload', files }
      }
      if (currentRun) await heartbeat('running').catch(() => {})
      return { kind: pending.kind, requestId: pending.requestId, answers }
    },
  }
}

// ---------------------------------------------------------------------------
// Roadie runtime access. Roadie loads plugins inside its own process; the
// shared conversation runtime is reached through the modules the registry
// documents for platform ingress (docs/chat-platforms.md, roadie#297). Tests
// and hosts can point WP_CODING_AGENTS_ROADIE_RUNTIME_MODULE at a module
// exporting the same functions.
// ---------------------------------------------------------------------------

const RUNTIME_MODULES = [
  'database.js',
  'channel-policy.js',
  'conversation-intake.js',
  'hrana-server.js',
  'session-handler/thread-session-runtime.js',
]

export async function loadRuntimeApi(env = process.env) {
  const spec = env.WP_CODING_AGENTS_ROADIE_RUNTIME_MODULE
  if (spec) return await import(pathToFileURL(path.resolve(spec)).href)
  const entry = process.argv[1]
  if (!entry) throw new Error('Cannot locate the Roadie runtime modules: no CLI entrypoint')
  const base = path.dirname(entry)
  const api = {}
  for (const name of RUNTIME_MODULES) Object.assign(api, await import(pathToFileURL(path.join(base, name)).href))
  if (typeof api.getOrCreateRuntime !== 'function') throw new Error('The Roadie runtime modules do not expose getOrCreateRuntime; set WP_CODING_AGENTS_ROADIE_RUNTIME_MODULE')
  return api
}

// ---------------------------------------------------------------------------
// The platform: ingress server + per-conversation state.
// ---------------------------------------------------------------------------

export function createWordPressPlatform({ configPath, runtimeApi, env = process.env } = {}) {
  const states = new Map() // conversationId -> state
  let runtime = runtimeApi ?? null

  const stateFor = (conversationId, found) => {
    let state = states.get(conversationId)
    if (state) return state
    const writer = createRunWriter(found.binding)
    const threadState = createWordPressChatThread({ contextKey: found.contextKey, conversationId, writer })
    state = { conversationId, contextKey: found.contextKey, binding: found.binding, writer, threadState, runs: new Map(), runtime: null }
    threadState.onAbortRequested(() => abortState(state))
    states.set(conversationId, state)
    return state
  }

  const abortState = async (state, runId) => {
    const threadId = state.threadState.thread.id
    if (state.runtime?.abort) await state.runtime.abort('Cancelled from WordPress')
    else if (runtime?.disposeRuntime) runtime.disposeRuntime(threadId)
    const run = (runId && state.runs.get(runId)) ?? state.threadState.currentRun()
    if (run) {
      await state.writer.status(run, 'cancelled').catch(() => {})
      state.threadState.markFinalized(run.runId)
    }
    state.threadState.thread.interactions.dispose()
  }

  // Mirror the shared intake path the native adapters use (roadie#297); every
  // piece is optional so a minimal backend (tests) still carries a turn.
  const ensureRuntime = async (state, parsed) => {
    const thread = state.threadState.thread
    const channelId = thread.parentId
    const policy = runtime.resolveChannelPolicy?.(channelId)
    if (policy === null) return new Error(`Channel ${channelId} is not configured in ROADIE_CHANNELS_CONFIG`)
    const projectDirectory = policy?.directory ?? state.binding.directory ?? state.binding.sitePath
    await runtime.setChannelDirectory?.({ channelId, directory: projectDirectory, channelType: 'text', guildId: state.contextKey })
    const actor = { platform: PLATFORM_ID, id: parsed.attributes.actor_user_id, name: `wp-user-${parsed.attributes.actor_user_id}` }
    const scope = { platform: PLATFORM_ID, spaceId: state.contextKey, threadId: thread.id }
    const hasSession = Boolean(await runtime.getThreadSession?.(thread.id))
    const admission = await runtime.readConversationAdmission?.(scope)
    const intake = (await runtime.resolveConversationIntake?.({
      actor,
      spaceId: state.contextKey,
      channelId,
      threadId: thread.id,
      text: parsed.message,
      eligible: true,
      isNewConversation: !hasSession && !admission,
      createsThread: !hasSession,
      hasSession,
      mentionsBot: false,
      isCommand: false,
      legacyOutcome: 'respond',
    })) ?? { outcome: 'respond' }
    if (intake.outcome === 'ignore') return null
    await runtime.recordConversationAdmission?.({ scope, actor, starter: !hasSession && !admission, decision: intake })
    state.runtime = runtime.getOrCreateRuntime({
      threadId: thread.id,
      chat: thread,
      projectDirectory,
      sdkDirectory: runtime.applicationDirectory?.() ?? projectDirectory,
      channelId,
      sessionId: (await runtime.getThreadSession?.(thread.id)) || undefined,
    })
    return intake
  }

  const enqueuePrompt = async (state, parsed, prompt, intake = { outcome: 'respond' }) => {
    await state.runtime.enqueueIncoming({
      prompt,
      userId: parsed.attributes.actor_user_id,
      username: `wp-user-${parsed.attributes.actor_user_id}`,
      actorPlatform: PLATFORM_ID,
      sourceThreadId: state.threadState.thread.id,
      sourceChannelId: state.threadState.thread.parentId,
      mode: 'direct',
      noReply: intake.outcome === 'context',
      contextOnly: intake.outcome === 'context',
    })
  }

  const handleTurn = async (config, parsed) => {
    const found = bindingForAgent(config, parsed.attributes.agent)
    if (!found) return { status: 422, error: `No WordPress context is bound to agent ${String(parsed.attributes.agent)}` }
    const claimToken = parsed.attributes.claim_token
    if (typeof claimToken !== 'string' || !claimToken) {
      return { status: 422, error: 'Turn event carried no claim_token; run writes cannot be authorized (agents-api#585)' }
    }
    const state = stateFor(parsed.conversationId, found)
    const run = { runId: parsed.attributes.run_id, claimToken }
    state.runs.set(run.runId, run)
    // Adopting the new run supersedes an unfinalized previous one (linking
    // event + terminal status), so a turn that takes over a waiting session
    // never strands the earlier run (#778).
    await state.threadState.adoptRun(run)
    state.threadState.recordIncoming(parsed.message, parsed.attributes.actor_user_id)
    // A turn that arrives while a question is open answers it; otherwise it
    // starts or continues the session through the shared intake path.
    if (state.threadState.thread.interactions.hasQuestion() && state.runtime) {
      await state.threadState.deliverAnswers([{ content: parsed.message, attachments: parsed.attachments }])
      await enqueuePrompt(state, parsed, parsed.message)
      return { status: 200, accepted: true, answered: true }
    }
    const intake = await ensureRuntime(state, parsed)
    if (intake instanceof Error) return { status: 422, error: intake.message }
    if (intake === null) {
      // Nothing will ever execute for this turn: finalize its run now so it
      // still ends in a terminal status.
      await state.threadState.heartbeat('completed').catch(() => {})
      return { status: 200, accepted: true, ignored: true }
    }
    await enqueuePrompt(state, parsed, parsed.message, intake)
    return { status: 200, accepted: true }
  }

  // A wake for queued answers (produced by WpCodingAgents_Runtime_Chat when a
  // WP client answers through agents/queue-chat-message): drain
  // agents/claim-chat-run-input for the same run and feed the pending
  // interaction (question/actions/upload round trip). The run that asked the
  // question resumes and later finalizes itself — no second run is spawned.
  const handleInput = async (parsed) => {
    const state = states.get(parsed.conversationId)
    const run = state?.runs.get(parsed.attributes.run_id) ?? state?.threadState.currentRun()
    if (!state || !run) return { status: 200, accepted: true, ignored: true }
    // Drain only when the drained answers have somewhere to go: a pending
    // interaction consumes them, or the live session runtime takes them as
    // follow-up prompts. With neither (e.g. the turn was ignored at intake),
    // claiming here would silently drop the answers — leave them durably
    // queued canonical-side for a future wake instead (#778).
    if (!state.threadState.thread.interactions.hasQuestion() && !state.runtime) {
      return { status: 200, accepted: true, ignored: true }
    }
    const result = await state.writer.claimInput(run)
    // Claimed queue items are canonical public_queue_item shapes: the answer
    // text is the `message` string (what agents/queue-chat-message stored),
    // alongside queued_message_id/run_id/attachments (agents-api#586).
    const answers = (Array.isArray(result.messages) ? result.messages : [])
      .map((item) => ({ content: typeof item?.message === 'string' ? item.message : '', attachments: item?.attachments }))
      .filter((answer) => answer.content || (Array.isArray(answer.attachments) && answer.attachments.length))
    const delivered = await state.threadState.deliverAnswers(answers)
    if (delivered?.kind === 'upload') return { status: 200, accepted: true, answered: true }
    // Claimed answers are never dropped: ones that matched a pending
    // question resume the session as its answer; ones that arrived without a
    // pending interaction continue the session as follow-up prompts (the
    // guard above guarantees a runtime exists whenever nothing was pending).
    const prompts = delivered ? delivered.answers : answers
    if (state.runtime) {
      for (const answer of prompts) {
        if (!answer.content) continue
        state.threadState.recordIncoming(answer.content, parsed.attributes.actor_user_id)
        await enqueuePrompt(state, parsed, answer.content)
      }
    }
    return { status: 200, accepted: true, answered: Boolean(delivered) }
  }

  // agents/cancel-chat-run reached WpCodingAgents_Runtime_Chat, which queued
  // a chat_cancel on the same conversation: abort the Roadie session and
  // finalize the run as cancelled.
  const handleCancel = async (parsed) => {
    const state = states.get(parsed.conversationId)
    if (!state) return { status: 200, accepted: true, ignored: true }
    await abortState(state, parsed.attributes.run_id)
    return { status: 200, accepted: true, cancelled: true }
  }

  const handleEvent = async (event) => {
    const parsed = validateEvent(event)
    if (parsed instanceof Error) return { status: 400, error: parsed.message }
    let config
    try { config = loadConfig(configPath) } catch (error) { return { status: 500, error: asError(error).message } }
    if (parsed.type === 'chat_cancel') return handleCancel(parsed)
    if (parsed.type === 'chat_input') return handleInput(parsed)
    return handleTurn(config, parsed)
  }

  const definition = {
    id: PLATFORM_ID,
    async start() {
      const ingress = ingressConfig(env)
      if (ingress instanceof Error) return ingress
      try { runtime = runtime ?? (await loadRuntimeApi(env)) } catch (error) { return asError(error) }
      runtime.setChannelParentResolver?.(
        (threadId) => (threadId.startsWith(`${PLATFORM_ID}:`) ? threadId.split(':').slice(0, 2).join(':') : undefined),
        { key: PLATFORM_ID },
      )
      const server = http.createServer((request, response) => {
        const respond = (status, payload) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(payload)) }
        if (request.method !== 'POST' || request.url !== ingress.url.pathname) { respond(404, { error: 'not found' }); return }
        const chunks = []
        let size = 0
        request.on('data', (chunk) => {
          size += chunk.length
          if (size > MAX_BODY_BYTES) { respond(413, { error: 'body too large' }); request.destroy(); return }
          chunks.push(chunk)
        })
        request.on('end', () => {
          const body = Buffer.concat(chunks)
          const timestamp = request.headers['x-wpcodingagents-request-timestamp']
          const signature = request.headers['x-wpcodingagents-signature']
          if (!verifySignature({ secret: ingress.secret, timestamp: String(timestamp ?? ''), signature, body })) { respond(401, { error: 'invalid signature' }); return }
          let payload
          try { payload = JSON.parse(body.toString('utf8')) } catch { respond(400, { error: 'invalid JSON' }); return }
          handleEvent(payload?.event)
            .then(({ status, ...rest }) => respond(status, rest))
            .catch((error) => respond(500, { error: asError(error).message }))
        })
      })
      await new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(Number(ingress.url.port), ingress.url.hostname, resolve)
      })
      runtime.markChatPlatformReady?.(PLATFORM_ID, true)
      return {
        address: server.address(),
        stop: async () => {
          runtime.markChatPlatformReady?.(PLATFORM_ID, false)
          for (const state of states.values()) {
            state.threadState.thread.interactions.dispose()
            runtime.disposeRuntime?.(state.threadState.thread.id)
          }
          states.clear()
          await new Promise((resolve) => server.close(resolve))
        },
      }
    },
  }

  // Run status follows the thread's *main* session only; the heartbeat's
  // `cancelled` echo aborts. Delegated child sessions (subagents) fire
  // session_idle/session_error with `parentSessionId` set and the same
  // threadId (roadie hooks.ts), so the first subagent finishing must not
  // finalize the user's run (#777). When the thread's main session is known,
  // an event for any other sessionId (stale or child) is ignored too.
  const sessionStateChanged = async (status, payload = {}) => {
    if (payload.parentSessionId) return
    const state = [...states.values()].find((entry) => entry.threadState.thread.id === payload.threadId)
    if (!state || !state.threadState.currentRun()) return
    if (payload.sessionId) {
      const mainSessionId = await Promise.resolve(runtime?.getThreadSession?.(payload.threadId)).catch(() => null)
      if (mainSessionId && payload.sessionId !== mainSessionId) return
    }
    // A Roadie-initiated abort settles as a plain idle (MessageAbortedError
    // is swallowed by handleSessionError); finalize as cancelled instead.
    const aborted = state.threadState.consumeAbortObservation()
    await state.threadState.heartbeat(status === 'completed' && aborted ? 'cancelled' : status).catch(() => {})
  }

  return { definition, handleEvent, sessionStateChanged, states }
}

export function register(roadie) {
  const configPath = process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG ?? fileURLToPath(new URL('../wordpress-context.json', import.meta.url))
  if (!fs.existsSync(configPath)) return
  const platform = createWordPressPlatform({ configPath })
  roadie.registerChatPlatform(platform.definition)
  for (const [action, status] of Object.entries(SESSION_STATUS)) {
    roadie.addAction(action, (payload) => platform.sessionStateChanged(status, payload))
  }
}
