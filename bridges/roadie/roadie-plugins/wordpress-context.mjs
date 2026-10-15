// WordPress decides who a chat actor is and what their seat may do; Roadie
// owns delivery. This plugin is a thin adapter over Data Machine's
// `datamachine/resolve-chat-person` ability (#711): the actor link lives on the
// WordPress user (`wp datamachine chat-identity link`), the role comes from the
// agent access grant, and memory comes from the registered memory store.
// wordpress-context.json only binds Roadie contexts to a site and agent.
// No display-name matching, owner fallback or global WP user mutation.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'

export const ABILITY = 'datamachine/resolve-chat-person'

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

// Per-person MCP servers for a context (Roadie person-MCP, roadie#152). Roadie
// registers each one with the speaker's own OAuth token (connected through
// Roadie's /connect) and scopes it to that speaker's turns. Entries mirror
// Roadie's own validation: names safe in tool ids, https (http on loopback).
const MCP_NAME = /^[a-z0-9][a-z0-9_-]{0,39}$/

export function mcpServersFor(binding) {
  const servers = []
  for (const entry of Array.isArray(binding?.mcpServers) ? binding.mcpServers : []) {
    if (!entry || typeof entry.name !== 'string' || typeof entry.url !== 'string') continue
    const credential = entry.credential ?? entry.name
    if (!MCP_NAME.test(entry.name) || typeof credential !== 'string' || !MCP_NAME.test(credential)) continue
    let url
    try { url = new URL(entry.url) } catch { continue }
    const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
    if (url.username || url.password || !(url.protocol === 'https:' || (url.protocol === 'http:' && loopback))) continue
    if (servers.some((server) => server.name === entry.name)) continue
    servers.push({ name: entry.name, url: entry.url, credential })
  }
  return servers
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

// Coding runtimes (Pi, OpenCode) load convention files such as AGENTS.md from
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

const DEFAULT_LOOKUP_TIMEOUT_MS = 12000

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
export function abilityPhp(input, { withSections = true } = {}) {
  const encoded = Buffer.from(JSON.stringify(input)).toString('base64')
  return [
    `$ability = function_exists( 'wp_get_ability' ) ? wp_get_ability( '${ABILITY}' ) : null;`,
    `if ( ! $ability ) { fwrite( STDERR, 'The ${ABILITY} ability is not registered.' . PHP_EOL ); exit( 1 ); }`,
    `$result = $ability->execute( json_decode( base64_decode( '${encoded}', true ), true ) );`,
    `if ( is_wp_error( $result ) ) { fwrite( STDERR, $result->get_error_code() . ': ' . $result->get_error_message() . PHP_EOL ); exit( 1 ); }`,
    ...(withSections ? [] : [`if ( is_array( $result ) ) { $result['sections'] = array(); }`]),
    `echo wp_json_encode( $result, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );`,
  ].join(' ')
}

function resolvePerson(binding, input, options) {
  const [command, ...prefix] = binding.transport
  return new Promise((resolve, reject) => {
    const timeout = lookupTimeoutMs(binding)
    execFile(command, [...prefix, `--path=${binding.sitePath}`, 'eval', abilityPhp(input, options), '--allow-root'], { timeout, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) { reject(new Error(`WordPress context lookup failed: ${describeLookupFailure(error, stderr, timeout)}`, { cause: error })); return }
      try { resolve(parseResolverStdout(stdout)) } catch (cause) { reject(new Error(cause instanceof Error ? cause.message : 'WordPress context returned invalid JSON', { cause })) }
    })
  })
}

function actorInput(actor) {
  if (!actor || typeof actor.platform !== 'string' || !actor.platform || typeof actor.id !== 'string' || !actor.id) return null
  return { platform: actor.platform, actor_id: actor.id }
}

const denied = () => ({ allowed: false, capabilities: new Set(), permissions: [] })

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
