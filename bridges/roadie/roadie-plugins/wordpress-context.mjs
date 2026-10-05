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
  if (!Array.isArray(capabilities) || capabilities.some((value) => !['sessions', 'shell', 'admin'].includes(value))) return null
  return { userId: entry.userId, capabilities }
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
      try { resolve(JSON.parse(stdout.trim())) } catch (cause) { reject(new Error('WordPress context returned invalid JSON', { cause })) }
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
    return { allowed: result.allowed === true, personId: `wordpress:${binding.sitePath}:${mapping.userId}`, capabilities: new Set(result.allowed === true ? mapping.capabilities : []), permissions: [] }
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
    return [...sections, ...result.sections]
  })
}
