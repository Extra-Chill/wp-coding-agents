// WordPress decides who a chat actor is and what their seat may do; Roadie
// owns delivery. This plugin is a thin adapter over Data Machine's
// `datamachine/resolve-chat-person` ability (#711): the actor link lives on the
// WordPress user (`wp datamachine chat-identity link`), the role comes from the
// agent access grant, and memory comes from the registered memory store.
// wordpress-context.json only binds Roadie contexts to a site and agent.
// No display-name matching, owner fallback or global WP user mutation.
// Self-serve linking (#765, roadie#292): a person who signed in at the site
// links their own chat actor through `datamachine/link-chat-identity`; access is
// still decided only by the agent access grant.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'

export const ABILITY = 'datamachine/resolve-chat-person'
export const LINK_ABILITY = 'datamachine/link-chat-identity'

let warnedPeople = false

function loadConfig(configPath) {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  if (config.version !== 1 || !config.contexts) throw new Error('Use version 1 with contexts in wordpress-context.json')
  if (config.people && !warnedPeople) {
    // Identity used to be mapped here. It now lives in Data Machine chat
    // identity links; a leftover `people` block grants nothing.
    warnedPeople = true
    console.warn('wordpress-context: `people` in wordpress-context.json is ignored; link chat actors with `wp datamachine chat-identity link` (#711)')
  }
  return config
}

export function resolveBinding(config, request) {
  // Hosts bind context IDs/project IDs, not a single channel-to-project pair.
  const key = request.contextId ?? request.projectId ?? config.defaultContext
  const binding = key ? config.contexts[key] : undefined
  if (!binding || typeof binding.sitePath !== 'string' || !path.isAbsolute(binding.sitePath) || typeof binding.agentSlug !== 'string' || !binding.agentSlug) return null
  const transport = binding.transport ?? ['wp']
  if (!Array.isArray(transport) || !transport.length || transport.some((arg) => typeof arg !== 'string' || !arg || arg.includes('\0'))) return null
  return { ...binding, transport }
}

// Session rules for a team seat (Data Machine operator/viewer). In Roadie the
// `shell` capability only gates user-typed raw shell; the agent's own tools
// follow the host runtime config, which on a WordPress host includes the
// operator's credentials. A team member's agent therefore gets no shell, no
// file writes and no reads outside the session directory, and works through
// abilities instead. wp-config.php holds the database credentials.
export const TEAM_SEAT_PERMISSIONS = Object.freeze([
  'bash:deny',
  'edit:deny',
  'external_directory:deny',
  'read:*wp-config.php:deny',
  'grep:*wp-config.php:deny',
])

const CAPABILITY_ORDER = ['sessions', 'shell', 'admin']

// Map the WordPress seat tier to Roadie's capabilities and session rules.
// An admin seat gets the full toolset (every Roadie capability, no rules); any
// other or unknown role is a team seat (fail closed to the restricted tier).
export function seatFor(role, capabilities = CAPABILITY_ORDER) {
  if (role === 'admin') return { capabilities: new Set(capabilities), permissions: [] }
  return { capabilities: new Set(capabilities.filter((value) => value === 'sessions')), permissions: [...TEAM_SEAT_PERMISSIONS] }
}

const DEFAULT_LOOKUP_TIMEOUT_MS = 12000

// Per-person MCP servers for a context (Roadie person-MCP, roadie#152). Roadie
// registers each one with the speaker's own OAuth token (connected through
// Roadie's /connect) and scopes it to that speaker's turns. Entries mirror
// Roadie's own validation: names safe in tool ids, https (http on loopback).
const MCP_NAME = /^[a-z0-9][a-z0-9_-]{0,39}$/

// https, or http on loopback; never credentials in the URL.
export function safeUrl(value) {
  if (typeof value !== 'string') return null
  let url
  try { url = new URL(value) } catch { return null }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  if (url.username || url.password || !(url.protocol === 'https:' || (url.protocol === 'http:' && loopback))) return null
  return url
}

export function mcpServersFor(binding) {
  const servers = []
  for (const entry of Array.isArray(binding?.mcpServers) ? binding.mcpServers : []) {
    if (!entry || typeof entry.name !== 'string' || typeof entry.url !== 'string') continue
    const credential = entry.credential ?? entry.name
    if (!MCP_NAME.test(entry.name) || typeof credential !== 'string' || !MCP_NAME.test(credential)) continue
    if (!safeUrl(entry.url)) continue
    if (servers.some((server) => server.name === entry.name)) continue
    servers.push({ name: entry.name, url: entry.url, credential })
  }
  return servers
}

// Self-serve identity linking (#765). `selfLink.server` names one of the
// context's valid mcpServers; Roadie runs the OAuth device grant against that
// protected resource. `userinfoUrl` (default: the server's origin +
// /wp-json/wp/v2/users/me) tells which WordPress user the token belongs to.
// Anything invalid disables linking for the context rather than guessing.
export function selfLinkFor(binding) {
  const selfLink = binding?.selfLink
  if (!selfLink || typeof selfLink !== 'object' || typeof selfLink.server !== 'string') return null
  const server = mcpServersFor(binding).find((entry) => entry.name === selfLink.server)
  if (!server) return null
  const userinfo = selfLink.userinfoUrl === undefined ? new URL('/wp-json/wp/v2/users/me', new URL(server.url).origin) : safeUrl(selfLink.userinfoUrl)
  if (!userinfo) return null
  return { server, userinfoUrl: userinfo.href }
}

// Ask the site who the token belongs to. WordPress answers /wp/v2/users/me for
// the user its bearer authentication resolved. Every failure becomes a plain
// sentence for the person; the token never appears in one.
export async function fetchUserId(userinfoUrl, access, { timeoutMs = DEFAULT_LOOKUP_TIMEOUT_MS, fetchImpl = fetch } = {}) {
  if (!safeUrl(userinfoUrl)) throw new Error('Account linking is misconfigured on this site; ask an admin.')
  let response
  try {
    // No redirects: a bearer token is only ever sent to the configured URL.
    response = await fetchImpl(userinfoUrl, { headers: { authorization: `Bearer ${access}`, accept: 'application/json' }, redirect: 'error', signal: AbortSignal.timeout(timeoutMs) })
  } catch (error) {
    if (error?.name === 'TimeoutError' || error?.name === 'AbortError') throw new Error("The site didn't answer in time while checking your sign-in. Try again in a moment.")
    throw new Error("Couldn't reach the site to check your sign-in. Try again in a moment.")
  }
  if (response.status === 401 || response.status === 403) throw new Error("The site didn't accept that sign-in. Try linking again.")
  if (!response.ok) throw new Error(`The site couldn't confirm your sign-in (HTTP ${response.status}). Try again later.`)
  let body
  try { body = await response.json() } catch { body = null }
  const id = body?.id
  if (!Number.isSafeInteger(id) || id <= 0) throw new Error("The site's answer didn't name a WordPress account. Ask an admin.")
  return id
}

// wp-cli shares stdout with PHP's error reporter, so the host's PHP build can
// emit diagnostics before the resolver's JSON. This mirrors the capture
// contract lib/common.sh wp_cli_strip_php_diagnostics() established for
// scalar shell captures (#494, #563): drop recognized leading diagnostic
// lines, then require the remainder to be the whole payload. Unrecognized
// output still fails loudly rather than being searched for something JSON-ish.
const PHP_DIAGNOSTIC = /^(?:PHP )?(?:Deprecated|Warning|Notice|Fatal error|Parse error):\s/

export function stripPhpDiagnostics(stdout) {
  const lines = String(stdout ?? '').split('\n')
  while (lines.length && !lines[0].trim()) lines.shift()
  while (lines.length && PHP_DIAGNOSTIC.test(lines[0].trimStart())) {
    lines.shift()
    while (lines.length && !lines[0].trim()) lines.shift()
  }
  return lines.join('\n').trim()
}

export function parseResolverStdout(stdout) {
  const text = stripPhpDiagnostics(stdout)
  if (!text) throw new Error('WordPress context returned no output')
  let value
  try {
    value = JSON.parse(text)
  } catch (cause) {
    throw new Error('WordPress context returned invalid JSON', { cause })
  }
  if (!value || typeof value !== 'object') {
    throw new Error('WordPress context returned invalid JSON')
  }
  return value
}

// the session directory and each of its ancestors. A section WordPress marks
// with a convention_path is skipped when the runtime will find that file on
// disk, so the model doesn't get the same text twice (#733). Without a copy on
// the path (a worktree outside the site, for example) it is still injected.
export function runtimeLoadsFile(directory, conventionPath) {
  if (typeof directory !== 'string' || !path.isAbsolute(directory)) return false
  if (typeof conventionPath !== 'string' || !conventionPath || path.isAbsolute(conventionPath)) return false
  for (let dir = path.resolve(directory); ; dir = path.dirname(dir)) {
    try {
      if (fs.statSync(path.join(dir, conventionPath)).isFile()) return true
    } catch {}
    if (path.dirname(dir) === dir) return false
  }
}

export function deliverableSections(sections, directory) {
  return sections
    .filter((section) => !section?.convention_path || !runtimeLoadsFile(directory, section.convention_path))
    .map(({ convention_path: _conventionPath, ...section }) => section)
}


// Local sites (for example a desktop WordPress app's WP-CLI) can boot slower
// than a server; a context may raise the bound with `lookupTimeoutMs`.
export function lookupTimeoutMs(binding) {
  const value = Number(binding?.lookupTimeoutMs)
  return Number.isFinite(value) && value >= 1000 && value <= 120000 ? Math.floor(value) : DEFAULT_LOOKUP_TIMEOUT_MS
}

// Roadie logs this message when the person filter throws. Name the actual
// failure (missing binary, timeout, exit status, PHP error) so an operator can
// fix it, without echoing stdout, which can carry memory content.
export function describeLookupFailure(error, stderr, timeout) {
  if (error?.code === 'ENOENT') return `command not found (${error.path ?? 'transport'}); check the context transport and the service PATH`
  if (error?.killed || error?.signal === 'SIGTERM') return `timed out after ${timeout}ms; raise lookupTimeoutMs on the context if the site is slow to boot`
  const detail = String(stderr ?? '').replace(/\s+/g, ' ').trim().slice(-300)
  const status = typeof error?.code === 'number' ? `exit ${error.code}` : (error?.signal ? `signal ${error.signal}` : 'failed')
  return detail ? `${status}: ${detail}` : status
}

// Ability sections are {name, layer, priority, content, convention_path?};
// Roadie sections are {id, title?, content}. Ids keep the shape the bridge has
// always used so pinned context stays stable across the switch.
export function roadieSections(sections) {
  if (!Array.isArray(sections)) throw new Error('WordPress context response has no sections')
  return sections.map((section) => {
    if (!section || typeof section.name !== 'string' || !section.name || typeof section.content !== 'string') throw new Error('WordPress context returned an invalid section')
    const layer = typeof section.layer === 'string' ? section.layer : ''
    const convention = typeof section.convention_path === 'string' && section.convention_path ? { convention_path: section.convention_path } : {}
    if (layer === 'runtime') return { id: section.name, content: section.content, ...convention }
    return { id: `wordpress-${layer}-${section.name}`, title: section.name, content: section.content, ...convention }
  })
}

// The ability runs inside WordPress through the configured transport. There is
// no generic ability CLI on every host, so this evaluates one public Abilities
// API call: no Data Machine class is touched from here. `withSections: false`
// drops memory from the output when only the admission decision is needed.
// `errorsAsJson` prints a WP_Error as {"error":{"code","message"}} (exit 0) so
// the caller can tell an expected refusal from a transport failure.
const ABILITY_NAME = /^[a-z0-9-]+\/[a-z0-9-]+$/

export function abilityPhp(ability, input, { withSections = true, errorsAsJson = false } = {}) {
  if (!ABILITY_NAME.test(ability)) throw new Error(`Invalid ability name: ${ability}`)
  const encoded = Buffer.from(JSON.stringify(input)).toString('base64')
  return [
    `$ability = function_exists( 'wp_get_ability' ) ? wp_get_ability( '${ability}' ) : null;`,
    `if ( ! $ability ) { fwrite( STDERR, 'The ${ability} ability is not registered.' . PHP_EOL ); exit( 1 ); }`,
    `$result = $ability->execute( json_decode( base64_decode( '${encoded}', true ), true ) );`,
    errorsAsJson
      ? `if ( is_wp_error( $result ) ) { echo wp_json_encode( array( 'error' => array( 'code' => $result->get_error_code(), 'message' => $result->get_error_message() ) ) ); return; }`
      : `if ( is_wp_error( $result ) ) { fwrite( STDERR, $result->get_error_code() . ': ' . $result->get_error_message() . PHP_EOL ); exit( 1 ); }`,
    ...(withSections ? [] : [`if ( is_array( $result ) ) { $result['sections'] = array(); }`]),
    `echo wp_json_encode( $result, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );`,
  ].join(' ')
}

function runAbility(binding, ability, input, options) {
  const [command, ...prefix] = binding.transport
  return new Promise((resolve, reject) => {
    const timeout = lookupTimeoutMs(binding)
    execFile(command, [...prefix, `--path=${binding.sitePath}`, 'eval', abilityPhp(ability, input, options), '--allow-root'], { timeout, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) { reject(new Error(`WordPress context lookup failed: ${describeLookupFailure(error, stderr, timeout)}`, { cause: error })); return }
      try { resolve(parseResolverStdout(stdout)) } catch (cause) { reject(new Error(cause instanceof Error ? cause.message : 'WordPress context returned invalid JSON', { cause })) }
    })
  })
}

const resolvePerson = (binding, input, options) => runAbility(binding, ABILITY, input, options)

function actorInput(actor) {
  if (!actor || typeof actor.platform !== 'string' || !actor.platform || typeof actor.id !== 'string' || !actor.id) return null
  return { platform: actor.platform, actor_id: actor.id }
}

const denied = () => ({ allowed: false, capabilities: new Set(), permissions: [] })
const notLinked = (reason) => ({ linked: false, reason })

// roadie#292 `link_identity`: verify the token with the site, then link the
// actor to the user it names. The ability is admin-only and permits WP-CLI as
// the host operator (like resolve-chat-person), so the adapter supplies the
// verified user id itself: a person can only ever link the chat account they
// are using to the WordPress account they signed in as. An actor already
// linked to someone else is refused by Data Machine (chat_identity_conflict).
export async function linkIdentity(binding, link, { actor, token }) {
  const who = actorInput(actor)
  if (!who) return notLinked("Couldn't tell which chat account to link.")
  if (typeof token?.access !== 'string' || !token.access) return notLinked('The sign-in did not return a usable token. Try linking again.')
  let userId
  try {
    userId = await fetchUserId(link.userinfoUrl, token.access, { timeoutMs: lookupTimeoutMs(binding) })
  } catch (error) {
    return notLinked(error.message)
  }
  let result
  try {
    result = await runAbility(binding, LINK_ABILITY, { user_id: userId, ...who }, { errorsAsJson: true })
  } catch (error) {
    console.warn(`wordpress-context: identity link failed: ${error.message}`)
    return notLinked("Couldn't record the link on the site. Try again later or ask an admin.")
  }
  if (result.error) {
    if (result.error.code === 'chat_identity_conflict') return notLinked('This chat account is already linked to a different WordPress account. Ask an admin to unlink it first.')
    console.warn(`wordpress-context: identity link refused: ${result.error.code}`)
    return notLinked(`The site refused the link (${result.error.code}). Ask an admin.`)
  }
  if (result.success !== true || result.user_id !== userId) return notLinked('The site gave an unexpected answer while linking. Ask an admin.')
  return { linked: true }
}

export function register(roadie) {
  const configPath = process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG ?? fileURLToPath(new URL('../wordpress-context.json', import.meta.url))
  if (!fs.existsSync(configPath)) return
  // Resolve fresh per callback. Roadie's own identity cache is opt-in TTL;
  // this provider does not retain users or context across conversations.
  roadie.addFilter('person', async (_person, { actor, context }) => {
    const config = loadConfig(configPath)
    const binding = resolveBinding(config, { contextId: config.channelContexts?.[context?.channelId] })
    const who = actorInput(actor)
    if (!binding || !who) return denied()
    // Links are platform-scoped, so the server/guild never takes part.
    const result = await resolvePerson(binding, { agent_slug: binding.agentSlug, ...who, event: 'person' }, { withSections: false })
    if (result.allowed !== true || !Number.isSafeInteger(result.user_id) || result.user_id <= 0) return denied()
    const mcpServers = mcpServersFor(binding)
    return { allowed: true, personId: `wordpress:${binding.sitePath}:${result.user_id}`, ...seatFor(result.role), ...(mcpServers.length ? { mcpServers } : {}) }
  })
  // roadie#292: offer self-serve linking only for contexts with `selfLink`.
  const selfLinkContext = (context) => {
    const config = loadConfig(configPath)
    const binding = resolveBinding(config, { contextId: config.channelContexts?.[context?.channelId] })
    const link = selfLinkFor(binding)
    return link ? { binding, link } : null
  }
  roadie.addFilter('identity_link_provider', async (provider, { actor, context }) => {
    const found = selfLinkContext(context)
    if (!found || !actorInput(actor)) return provider ?? null
    const { url, name, credential } = found.link.server
    return { url, name, credential }
  })
  roadie.addFilter('link_identity', async (result, { actor, context, token }) => {
    const found = selfLinkContext(context)
    if (!found) return result ?? notLinked("This site doesn't offer account linking here.")
    return linkIdentity(found.binding, found.link, { actor, token })
  })
  roadie.addFilter('context_sections', async (sections, request) => {
    const config = loadConfig(configPath)
    const binding = resolveBinding(config, { ...request, contextId: request.contextId ?? config.channelContexts?.[request.channelId] })
    if (!binding) return sections
    if (request.event === 'turn') {
      // Personal memory needs a platform-authenticated person (Roadie sets
      // personId only for those) whose actor still resolves to that user.
      const prefix = `wordpress:${binding.sitePath}:`
      const user = typeof request.personId === 'string' && request.personId.startsWith(prefix) ? Number(request.personId.slice(prefix.length)) : 0
      const who = actorInput(request.actor)
      if (!Number.isSafeInteger(user) || user <= 0 || !who) return sections
      const result = await resolvePerson(binding, { agent_slug: binding.agentSlug, ...who, event: 'turn' })
      if (result.allowed !== true || result.user_id !== user) return sections
      return [...sections, ...deliverableSections(roadieSections(result.sections), request.directory)]
    }
    // Shared context is pinned without a speaker: ask for agent-layer memory
    // only. Data Machine answers allowed:false, reason no_actor (#3615).
    const result = await resolvePerson(binding, { agent_slug: binding.agentSlug, platform: actorInput(request.actor)?.platform ?? '', actor_id: '', event: request.event })
    if (result.reason !== 'no_actor') throw new Error(`WordPress agent context unavailable (${result.reason || 'unexpected response'}); needs Data Machine with actorless resolve-chat-person (data-machine#3615)`)
    return [...sections, ...deliverableSections(roadieSections(result.sections), request.directory)]
  })
}
