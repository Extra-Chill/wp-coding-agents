// WordPress owns actor mapping and registered memory. Roadie owns delivery.
// Context is explicit: no display-name matching, owner fallback or global WP
// user mutation. Configure mappings in operator-owned wordpress-context.json.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'

const resolver = fileURLToPath(new URL('./wordpress-context.php', import.meta.url))

function loadConfig(configPath) {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  if (config.version !== 1 || !config.contexts || !config.people) throw new Error('Use version 1 with contexts and people in wordpress-context.json')
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

export function actorMapping(config, actor, spaceId) {
  if (!actor || typeof actor.platform !== 'string' || typeof actor.id !== 'string' || !spaceId) return null
  const entry = config.people[`${actor.platform}:${spaceId}:${actor.id}`]
  if (!entry || !Number.isSafeInteger(entry.userId) || entry.userId <= 0) return null
  const capabilities = entry.capabilities ?? ['sessions']
  if (!Array.isArray(capabilities) || capabilities.some((value) => !CAPABILITY_ORDER.includes(value))) return null
  return { userId: entry.userId, capabilities }
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
// Only an admin seat keeps the capabilities the operator declared; any other
// or unknown role is a team seat (fail closed to the restricted tier).
export function seatFor(role, capabilities) {
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

function invoke(binding, input) {
  const code = fs.readFileSync(resolver, 'utf8').replace(/^<\?php\s*/, '')
  const encoded = Buffer.from(JSON.stringify(input)).toString('base64')
  // The local code is host-owned; remote control transports can execute this
  // same bounded read without copying PHP or memory files into the runtime.
  const php = `$args=array('${encoded}');${code}`
  const [command, ...prefix] = binding.transport
  return new Promise((resolve, reject) => {
    execFile(command, [...prefix, `--path=${binding.sitePath}`, 'eval', php, '--allow-root'], { timeout: 12000, maxBuffer: 256 * 1024 }, (error, stdout) => {
      if (error) { reject(new Error('WordPress context lookup failed', { cause: error })); return }
      try { resolve(parseResolverStdout(stdout)) } catch (cause) { reject(new Error(cause instanceof Error ? cause.message : 'WordPress context returned invalid JSON', { cause })) }
    })
  })
}

export function register(roadie) {
  const configPath = process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG ?? fileURLToPath(new URL('../wordpress-context.json', import.meta.url))
  if (!fs.existsSync(configPath)) return
  // Resolve mappings fresh per callback. Roadie's own identity cache is opt-in
  // TTL; this provider does not retain users or context across conversations.
  roadie.addFilter('person', async (_person, { actor, context }) => {
    const config = loadConfig(configPath)
    const binding = resolveBinding(config, { contextId: config.channelContexts?.[context.channelId] })
    const mapping = actorMapping(config, actor, context.guildId)
    if (!binding || !mapping) return { allowed: false, capabilities: new Set(), permissions: [] }
    const result = await invoke(binding, { operation: 'person', user_id: mapping.userId, agent_slug: binding.agentSlug, actor })
    if (result.allowed !== true) return { allowed: false, capabilities: new Set(), permissions: [] }
    const mcpServers = mcpServersFor(binding)
    return { allowed: true, personId: `wordpress:${binding.sitePath}:${mapping.userId}`, ...seatFor(result.role, mapping.capabilities), ...(mcpServers.length ? { mcpServers } : {}) }
  })
  roadie.addFilter('context_sections', async (sections, request) => {
    const config = loadConfig(configPath)
    const binding = resolveBinding(config, { ...request, contextId: request.contextId ?? config.channelContexts?.[request.channelId] })
    if (!binding) return sections
    const prefix = `wordpress:${binding.sitePath}:`
    const user = typeof request.personId === 'string' && request.personId.startsWith(prefix) ? Number(request.personId.slice(prefix.length)) : 0
    const mapping = actorMapping(config, request.actor, request.spaceId)
    if (request.event === 'turn' && (!mapping || mapping.userId !== user)) return sections
    const result = await invoke(binding, { operation: 'context', event: request.event, user_id: request.event === 'turn' ? user : 0, agent_slug: binding.agentSlug, actor: request.actor })
    if (!Array.isArray(result.sections)) throw new Error('WordPress context response has no sections')
    return [...sections, ...deliverableSections(result.sections, request.directory)]
  })
}
