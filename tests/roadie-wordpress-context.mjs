import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

// wp-cli writes PHP notices to the same stdout as `eval` output; the resolver
// response has to survive that preamble (Roadie fails identity closed otherwise).
const PHP_NOTICE = 'PHP Deprecated:  Case statements followed by a semicolon (;) are deprecated, use a colon (:) instead in phar:///opt/homebrew/Cellar/wp-cli/2.12.0/bin/wp/vendor/react/promise/src/functions.php on line 369\n\nDeprecated: Case statements followed by a semicolon (;) are deprecated, use a colon (:) instead in phar:///opt/homebrew/Cellar/wp-cli/2.12.0/bin/wp/vendor/react/promise/src/functions.php on line 369\n'
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'roadie-wp-context-'))
const configPath = path.join(temp, 'wordpress-context.json')
const wp = path.join(temp, 'wp.mjs')
const calls = path.join(temp, 'calls.jsonl')
fs.writeFileSync(wp, `import fs from 'node:fs'; const noise=${JSON.stringify(PHP_NOTICE)}; const args=process.argv.slice(2); const code=args[args.indexOf('eval')+1]; const match=code.match(/\\$args=array\\('([^']+)'\\)/); const req=JSON.parse(Buffer.from(match[1],'base64')); fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify(req)+'\\n'); process.stdout.write(noise); process.stdout.write(JSON.stringify(req.operation==='person'?({1:{allowed:true,role:'admin'},2:{allowed:true,role:'viewer'},3:{allowed:true,role:'operator'},4:{allowed:true},5:{allowed:false,role:''}})[req.user_id]??{allowed:false,role:''}:{sections:req.event==='turn'?[{id:'user',content:'USER_'+req.user_id}]:[{id:'shared',content:'SHARED'},{id:'agents',title:'AGENTS.md',content:'AGENTS',convention_path:'AGENTS.md'}]}));`)
const config = {
  version: 1, defaultContext: 'franklin',
  contexts: { franklin: { sitePath: '/site', agentSlug: 'franklin', transport: [process.execPath, wp], mcpServers: [
    { name: 'site', url: 'https://example.test/wp-json/mcp' },
    { name: 'site', url: 'https://dupe.test/mcp' },
    { name: 'Bad Name', url: 'https://example.test/mcp' },
    { name: 'plain', url: 'http://example.test/mcp' },
    { name: 'creds', url: 'https://user:pass@example.test/mcp' },
    { name: 'local', url: 'http://127.0.0.1:8080/mcp', credential: 'local-cred' },
    { name: 'badcred', url: 'https://example.test/mcp', credential: '../x' },
    'nope',
  ] } },
  people: { 'discord:GUILD:ALICE': { userId: 1, capabilities: ['sessions'] }, 'slack:TEAM:BOB': { userId: 2, capabilities: ['sessions'] },
    'discord:GUILD:ADMIN': { userId: 1, capabilities: ['sessions', 'shell', 'admin'] },
    'discord:GUILD:CAROL': { userId: 3, capabilities: ['sessions', 'shell', 'admin'] },
    'discord:GUILD:NOROLE': { userId: 4, capabilities: ['sessions', 'shell'] },
    'discord:GUILD:DENIED': { userId: 5, capabilities: ['sessions', 'shell', 'admin'] } },
}
fs.writeFileSync(configPath, JSON.stringify(config))
process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG = configPath
const module = await import(pathToFileURL(path.resolve(import.meta.dirname, '../bridges/roadie/roadie-plugins/wordpress-context.mjs')))
const filters = {}
module.register({ addFilter(name, fn) { filters[name] = fn } })
try {
  const alice = await filters.person(null, { actor: { platform: 'discord', id: 'ALICE' }, context: { guildId: 'GUILD', channelId: 'C1' } })
  const bob = await filters.person(null, { actor: { platform: 'slack', id: 'BOB' }, context: { guildId: 'TEAM', channelId: 'C2' } })
  assert.equal(alice.personId, 'wordpress:/site:1')
  assert.equal(bob.personId, 'wordpress:/site:2')
  assert.deepEqual([...alice.capabilities], ['sessions'])
  assert.equal((await filters.person(null, { actor: { platform: 'discord', id: 'ALICE' }, context: { guildId: 'OTHER' } })).allowed, false)
  // #711 seat tiers: the Data Machine access role decides the seat, not the
  // capabilities written in the mapping. Admin keeps the declared
  // capabilities and an unrestricted toolset; operator and viewer seats get
  // sessions only plus deny rules for shell, writes and host reads.
  const seat = (id) => filters.person(null, { actor: { platform: 'discord', id }, context: { guildId: 'GUILD', channelId: 'C1' } })
  const admin = await seat('ADMIN')
  assert.equal(admin.allowed, true)
  assert.deepEqual([...admin.capabilities], ['sessions', 'shell', 'admin'])
  assert.deepEqual(admin.permissions, [])
  assert.deepEqual(alice.permissions, [], 'admin role with a sessions-only mapping stays unrestricted')
  for (const [person, label] of [[bob, 'viewer'], [await seat('CAROL'), 'operator'], [await seat('NOROLE'), 'missing role']]) {
    assert.equal(person.allowed, true, label)
    assert.deepEqual([...person.capabilities], ['sessions'], `${label} seat drops shell/admin`)
    assert.deepEqual(person.permissions, [...module.TEAM_SEAT_PERMISSIONS], `${label} seat is restricted`)
  }
  for (const rule of ['bash:deny', 'edit:deny', 'external_directory:deny']) assert(module.TEAM_SEAT_PERMISSIONS.includes(rule), rule)
  // #748: allowed seats (any tier) carry the context's valid per-person MCP servers.
  const servers = [{ name: 'site', url: 'https://example.test/wp-json/mcp', credential: 'site' }, { name: 'local', url: 'http://127.0.0.1:8080/mcp', credential: 'local-cred' }]
  assert.deepEqual(admin.mcpServers, servers)
  assert.deepEqual(bob.mcpServers, servers)
  assert.deepEqual(module.mcpServersFor({}), [])
  const denied = await seat('DENIED')
  assert.equal(denied.mcpServers, undefined)
  assert.deepEqual([denied.allowed, [...denied.capabilities], denied.permissions, denied.personId], [false, [], [], undefined])
  assert.equal((await seat('UNMAPPED')).allowed, false)
  // The returned permissions are a copy: mutating one seat leaves the next intact.
  bob.permissions.push('bash:allow')
  assert.deepEqual((await seat('CAROL')).permissions, [...module.TEAM_SEAT_PERMISSIONS])
  assert.throws(() => module.TEAM_SEAT_PERMISSIONS.push('x'))
  const shared = await filters.context_sections([], { event: 'session_start', contextId: 'franklin' })
  // #733: a convention file is injected (without its marker) unless the
  // runtime loads it from the session directory or one of its ancestors.
  assert.deepEqual(shared, [{ id: 'shared', content: 'SHARED' }, { id: 'agents', title: 'AGENTS.md', content: 'AGENTS' }])
  const site = path.join(temp, 'site')
  const nested = path.join(site, 'wp-content', 'plugins')
  fs.mkdirSync(nested, { recursive: true })
  const startIn = (directory) => filters.context_sections([], { event: 'session_start', contextId: 'franklin', directory })
  assert.deepEqual(await startIn(site), [{ id: 'shared', content: 'SHARED' }, { id: 'agents', title: 'AGENTS.md', content: 'AGENTS' }])
  fs.writeFileSync(path.join(site, 'AGENTS.md'), 'on disk')
  assert.deepEqual(await startIn(site), [{ id: 'shared', content: 'SHARED' }])
  assert.deepEqual(await startIn(nested), [{ id: 'shared', content: 'SHARED' }])
  assert.equal(module.runtimeLoadsFile(path.join(temp, 'elsewhere'), 'AGENTS.md'), false)
  assert.equal(module.runtimeLoadsFile('relative/dir', 'AGENTS.md'), false)
  assert.equal(module.runtimeLoadsFile(site, path.join(site, 'AGENTS.md')), false)
  fs.mkdirSync(path.join(temp, 'dir-not-file', 'AGENTS.md'), { recursive: true })
  assert.equal(module.runtimeLoadsFile(path.join(temp, 'dir-not-file'), 'AGENTS.md'), false)
  const turn = (personId, actor, spaceId) => filters.context_sections([], { event: 'turn', contextId: 'franklin', personId, actor, spaceId })
  const [one, two] = await Promise.all([turn(alice.personId, { platform: 'discord', id: 'ALICE' }, 'GUILD'), turn(bob.personId, { platform: 'slack', id: 'BOB' }, 'TEAM')])
  assert.deepEqual(one, [{ id: 'user', content: 'USER_1' }])
  assert.deepEqual(two, [{ id: 'user', content: 'USER_2' }])
  assert.deepEqual(await turn(alice.personId, { platform: 'slack', id: 'BOB' }, 'TEAM'), [])
  assert.deepEqual(await turn(alice.personId, undefined, 'GUILD'), [])
  assert.deepEqual(await turn(alice.personId, { platform: 'discord', id: 'ALICE' }, 'OTHER'), [])
  // Delete a mapping between sequential turns: no stale provider cache.
  delete config.people['discord:GUILD:ALICE']
  fs.writeFileSync(configPath, JSON.stringify(config))
  assert.deepEqual(await turn(alice.personId, { platform: 'discord', id: 'ALICE' }, 'GUILD'), [])
  const requests = fs.readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse)
  assert(requests.every((req) => !('acting_user_id' in req)))
  assert.equal(requests.filter((req) => req.operation === 'context' && req.event === 'turn').length, 2)
  // The helper itself: recognized diagnostics dropped, payload preserved,
  // unrecognized output still rejected rather than scanned for JSON.
  assert.deepEqual(module.parseResolverStdout(PHP_NOTICE + '{"allowed":true}'), { allowed: true })
  assert.deepEqual(module.parseResolverStdout('{"allowed":true}'), { allowed: true })
  assert.deepEqual(module.parseResolverStdout(PHP_NOTICE + '{"sections":[{"id":"a","content":"{nested}"}]}'), { sections: [{ id: 'a', content: '{nested}' }] })
  for (const kind of ['PHP Deprecated', 'Deprecated', 'Warning', 'PHP Warning', 'Notice']) {
    assert.deepEqual(module.parseResolverStdout(`${kind}:  something in file.php on line 1\n\n{"allowed":true}`), { allowed: true })
  }
  // A payload that is itself pretty-printed across lines still parses whole.
  assert.deepEqual(module.parseResolverStdout(PHP_NOTICE + '{\n  "allowed": true\n}'), { allowed: true })
  assert.throws(() => module.parseResolverStdout(PHP_NOTICE), /no output/)
  assert.throws(() => module.parseResolverStdout('   '), /no output/)
  // Unrecognized leading noise is a real failure, not something to scan past.
  assert.throws(() => module.parseResolverStdout('Xdebug is broken {"allowed":true}'), /invalid JSON/)
  assert.throws(() => module.parseResolverStdout('"just a string"'), /invalid JSON/)
  assert.equal(module.stripPhpDiagnostics(PHP_NOTICE + '{"a":1}'), '{"a":1}')
  // Lookup failures name their cause; the timeout is configurable per context.
  assert.equal(module.lookupTimeoutMs({}), 12000)
  assert.equal(module.lookupTimeoutMs({ lookupTimeoutMs: 45000 }), 45000)
  assert.equal(module.lookupTimeoutMs({ lookupTimeoutMs: 5 }), 12000)
  assert.equal(module.lookupTimeoutMs({ lookupTimeoutMs: 'x' }), 12000)
  assert.match(module.describeLookupFailure({ code: 'ENOENT', path: 'wp' }, '', 12000), /command not found \(wp\)/)
  assert.match(module.describeLookupFailure({ killed: true, signal: 'SIGTERM' }, '', 12000), /timed out after 12000ms/)
  assert.equal(module.describeLookupFailure({ code: 255 }, 'PHP Fatal error:  Uncaught Error: Class "X" not found\n', 12000), 'exit 255: PHP Fatal error: Uncaught Error: Class "X" not found')
  assert.equal(module.describeLookupFailure({ code: 1 }, '', 12000), 'exit 1')
  const slow = path.join(temp, 'slow-wp.mjs')
  fs.writeFileSync(slow, 'setTimeout(() => {}, 5000)\n')
  const slowConfig = path.join(temp, 'slow-context.json')
  fs.writeFileSync(slowConfig, JSON.stringify({ version: 1, defaultContext: 's', contexts: { s: { sitePath: '/site', agentSlug: 's', transport: [process.execPath, slow], lookupTimeoutMs: 1000 } }, people: { 'discord:g1:u1': { userId: 1, capabilities: ['sessions'] } } }))
  process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG = slowConfig
  const slowFilters = {}
  module.register({ addFilter: (name, fn) => { slowFilters[name] = fn } })
  await assert.rejects(slowFilters.person({}, { actor: { platform: 'discord', id: 'u1' }, context: { guildId: 'g1' } }), /WordPress context lookup failed: timed out after 1000ms/)
  console.log('PASS: seat tiers from the agent access role (admin unrestricted, operator/viewer restricted, denied/unmapped rejected), isolated concurrent user context, explicit scoped identity, unmapped and asserted actor rejection, PHP-notice stdout tolerated')
} finally {
  delete process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG
  fs.rmSync(temp, { recursive: true, force: true })
}
