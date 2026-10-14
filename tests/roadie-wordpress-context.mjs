import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

// wp-cli writes PHP notices to the same stdout as `eval` output; the ability
// response has to survive that preamble (Roadie fails identity closed otherwise).
const PHP_NOTICE = 'PHP Deprecated:  Case statements followed by a semicolon (;) are deprecated, use a colon (:) instead in phar:///opt/homebrew/Cellar/wp-cli/2.12.0/bin/wp/vendor/react/promise/src/functions.php on line 369\n\nDeprecated: Case statements followed by a semicolon (;) are deprecated, use a colon (:) instead in phar:///opt/homebrew/Cellar/wp-cli/2.12.0/bin/wp/vendor/react/promise/src/functions.php on line 369\n'
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'roadie-wp-context-'))
const configPath = path.join(temp, 'wordpress-context.json')
const wp = path.join(temp, 'wp.mjs')
const calls = path.join(temp, 'calls.jsonl')
const state = path.join(temp, 'state.json')

// Fake WordPress: plays Data Machine's datamachine/resolve-chat-person against
// platform-scoped chat identity links (ChatIdentityLinks) and agent access
// roles (ChatPersonResolver). `old` mimics Data Machine before #3615, which
// denied an actorless request as actor_not_linked with no sections.
fs.writeFileSync(state, JSON.stringify({
  links: { 'discord:ALICE': 1, 'slack:BOB': 2, 'discord:CAROL': 3, 'discord:NOROLE': 4, 'discord:DENIED': 5 },
  roles: { 1: 'admin', 2: 'viewer', 3: 'operator', 4: '' },
  old: false,
}))
fs.writeFileSync(wp, `import fs from 'node:fs'
const args = process.argv.slice(2)
const code = args[args.indexOf('eval') + 1]
if (!code.includes("wp_get_ability( 'datamachine/resolve-chat-person' )")) { process.stderr.write('not the ability'); process.exit(1) }
const req = JSON.parse(Buffer.from(code.match(/base64_decode\\( '([^']+)'/)[1], 'base64'))
const withSections = !code.includes("$result['sections'] = array();")
fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify({ ...req, withSections, argv: args.filter((arg) => arg !== code) }) + '\\n')
const { links, roles, old } = JSON.parse(fs.readFileSync(${JSON.stringify(state)}, 'utf8'))
const deny = (user_id, reason) => ({ allowed: false, user_id, role: '', sections: [], reason })
const agent = [{ name: 'SOUL.md', layer: 'agent', priority: 10, content: 'SOUL' }, { name: 'AGENTS.md', layer: 'shared', priority: 12, content: 'AGENTS', convention_path: 'AGENTS.md' }]
let out
if (req.agent_slug !== 'franklin') out = deny(0, 'agent_not_found')
else if (!req.actor_id) out = req.event === 'turn' || old ? deny(0, old ? 'actor_not_linked' : 'no_actor') : { ...deny(0, 'no_actor'), sections: agent }
else {
  const user = links[req.platform + ':' + req.actor_id] ?? 0
  if (!user) out = deny(0, 'actor_not_linked')
  else if (!(user in roles)) out = deny(user, 'access_denied')
  else out = { allowed: true, user_id: user, role: roles[user], reason: '', sections: req.event === 'turn'
    ? [{ name: 'wordpress-current-user', layer: 'runtime', priority: 0, content: 'The current speaker is WordPress user ID ' + user + '.' }, { name: 'USER.md', layer: 'user', priority: 25, content: 'USER_' + user }]
    : agent }
}
if (!withSections) out.sections = []
process.stdout.write(${JSON.stringify(PHP_NOTICE)})
process.stdout.write(JSON.stringify(out))
`)
const mcpServers = [
  { name: 'site', url: 'https://example.test/wp-json/mcp' },
  { name: 'site', url: 'https://dupe.test/mcp' },
  { name: 'Bad Name', url: 'https://example.test/mcp' },
  { name: 'plain', url: 'http://example.test/mcp' },
  { name: 'creds', url: 'https://user:pass@example.test/mcp' },
  { name: 'local', url: 'http://127.0.0.1:8080/mcp', credential: 'local-cred' },
  { name: 'badcred', url: 'https://example.test/mcp', credential: '../x' },
  'nope',
]
// No `people` block: identity lives in Data Machine chat identity links.
const config = {
  version: 1, defaultContext: 'franklin',
  contexts: {
    franklin: { sitePath: '/site', agentSlug: 'franklin', transport: [process.execPath, wp], mcpServers },
    ghost: { sitePath: '/site', agentSlug: 'ghost', transport: [process.execPath, wp] },
  },
  channelContexts: { GHOST: 'ghost' },
}
fs.writeFileSync(configPath, JSON.stringify(config))
const setState = (update) => fs.writeFileSync(state, JSON.stringify({ ...JSON.parse(fs.readFileSync(state, 'utf8')), ...update }))
const readCalls = () => fs.readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse)
process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG = configPath
const module = await import(pathToFileURL(path.resolve(import.meta.dirname, '../bridges/roadie/roadie-plugins/wordpress-context.mjs')))
const filters = {}
module.register({ addFilter(name, fn) { filters[name] = fn } })
try {
  const person = (platform, id, guildId = 'GUILD', channelId = 'C1') => filters.person(null, { actor: { platform, id }, context: { guildId, channelId } })
  const alice = await person('discord', 'ALICE')
  const bob = await person('slack', 'BOB', 'TEAM', 'C2')
  assert.equal(alice.personId, 'wordpress:/site:1')
  assert.equal(bob.personId, 'wordpress:/site:2')
  // The adapter asks the ability only for the admission decision here.
  const first = readCalls()[0]
  assert.deepEqual({ ...first, argv: undefined }, { agent_slug: 'franklin', platform: 'discord', actor_id: 'ALICE', event: 'person', withSections: false, argv: undefined })
  assert.deepEqual(first.argv, ['--path=/site', 'eval', '--allow-root'])
  // #711: links are platform-scoped. Moving the bot to another server needs
  // no config change; the guild never takes part in the lookup.
  const moved = await person('discord', 'ALICE', 'NEW_SERVER')
  assert.deepEqual([moved.allowed, moved.personId], [true, 'wordpress:/site:1'])
  // Seat tiers: the Data Machine access role decides the seat. Admin gets the
  // full toolset; operator, viewer and a missing role get sessions only plus
  // deny rules for shell, writes and host reads.
  assert.deepEqual([...alice.capabilities], ['sessions', 'shell', 'admin'])
  assert.deepEqual(alice.permissions, [])
  for (const [seat, label] of [[bob, 'viewer'], [await person('discord', 'CAROL'), 'operator'], [await person('discord', 'NOROLE'), 'missing role']]) {
    assert.equal(seat.allowed, true, label)
    assert.deepEqual([...seat.capabilities], ['sessions'], `${label} seat drops shell/admin`)
    assert.deepEqual(seat.permissions, [...module.TEAM_SEAT_PERMISSIONS], `${label} seat is restricted`)
  }
  for (const rule of ['bash:deny', 'edit:deny', 'external_directory:deny']) assert(module.TEAM_SEAT_PERMISSIONS.includes(rule), rule)
  assert.deepEqual([...module.seatFor('admin', ['sessions']).capabilities], ['sessions'])
  assert.deepEqual(module.seatFor('surprise').permissions, [...module.TEAM_SEAT_PERMISSIONS])
  // #748: allowed seats (any tier) carry the context's valid per-person MCP servers.
  const servers = [{ name: 'site', url: 'https://example.test/wp-json/mcp', credential: 'site' }, { name: 'local', url: 'http://127.0.0.1:8080/mcp', credential: 'local-cred' }]
  assert.deepEqual(alice.mcpServers, servers)
  assert.deepEqual(bob.mcpServers, servers)
  assert.deepEqual(module.mcpServersFor({}), [])
  // Fail closed: no access, unlinked actor, a platform the actor is not linked
  // on, a missing actor and an unknown agent are all denied without a person.
  const closed = (seat) => assert.deepEqual([seat.allowed, [...seat.capabilities], seat.permissions, seat.personId, seat.mcpServers], [false, [], [], undefined, undefined])
  closed(await person('discord', 'DENIED'))
  closed(await person('discord', 'UNMAPPED'))
  closed(await person('slack', 'ALICE'))
  closed(await filters.person(null, { actor: undefined, context: { guildId: 'GUILD', channelId: 'C1' } }))
  closed(await person('discord', 'ALICE', 'GUILD', 'GHOST'))
  // The returned permissions are a copy: mutating one seat leaves the next intact.
  bob.permissions.push('bash:allow')
  assert.deepEqual((await person('discord', 'CAROL')).permissions, [...module.TEAM_SEAT_PERMISSIONS])
  assert.throws(() => module.TEAM_SEAT_PERMISSIONS.push('x'))

  // Shared context is pinned without a speaker: the actor is never sent, and
  // Data Machine's no_actor answer carries the agent-layer sections.
  const agentSections = [{ id: 'wordpress-agent-SOUL.md', title: 'SOUL.md', content: 'SOUL' }, { id: 'wordpress-shared-AGENTS.md', title: 'AGENTS.md', content: 'AGENTS' }]
  fs.writeFileSync(calls, '')
  const shared = await filters.context_sections([{ id: 'prior', content: 'P' }], { event: 'session_start', contextId: 'franklin', actor: { platform: 'discord', id: 'ALICE' } })
  assert.deepEqual(shared, [{ id: 'prior', content: 'P' }, ...agentSections])
  assert.deepEqual(readCalls().map(({ argv: _argv, ...req }) => req), [{ agent_slug: 'franklin', platform: 'discord', actor_id: '', event: 'session_start', withSections: true }])
  // #733: a convention file is injected (without its marker) unless the
  // runtime loads it from the session directory or one of its ancestors.
  const site = path.join(temp, 'site')
  const nested = path.join(site, 'wp-content', 'plugins')
  fs.mkdirSync(nested, { recursive: true })
  const startIn = (directory) => filters.context_sections([], { event: 'session_start', contextId: 'franklin', directory })
  assert.deepEqual(await startIn(site), agentSections)
  fs.writeFileSync(path.join(site, 'AGENTS.md'), 'on disk')
  assert.deepEqual(await startIn(site), [agentSections[0]])
  assert.deepEqual(await startIn(nested), [agentSections[0]])
  assert.equal(module.runtimeLoadsFile(path.join(temp, 'elsewhere'), 'AGENTS.md'), false)
  assert.equal(module.runtimeLoadsFile('relative/dir', 'AGENTS.md'), false)
  assert.equal(module.runtimeLoadsFile(site, path.join(site, 'AGENTS.md')), false)
  fs.mkdirSync(path.join(temp, 'dir-not-file', 'AGENTS.md'), { recursive: true })
  assert.equal(module.runtimeLoadsFile(path.join(temp, 'dir-not-file'), 'AGENTS.md'), false)
  // Data Machine before #3615 cannot answer without an actor: fail loudly
  // (Roadie logs it and continues) rather than silently dropping memory.
  setState({ old: true })
  await assert.rejects(startIn(site), /data-machine#3615/)
  setState({ old: false })
  await assert.rejects(filters.context_sections([], { event: 'session_start', contextId: 'ghost' }), /agent_not_found/)

  // Turns: personal memory for the speaker Roadie authenticated, isolated
  // between concurrent speakers.
  const turn = (personId, actor, spaceId = 'GUILD') => filters.context_sections([], { event: 'turn', contextId: 'franklin', personId, actor, spaceId })
  const userSections = (id) => [{ id: 'wordpress-current-user', content: `The current speaker is WordPress user ID ${id}.` }, { id: 'wordpress-user-USER.md', title: 'USER.md', content: `USER_${id}` }]
  const [one, two] = await Promise.all([turn(alice.personId, { platform: 'discord', id: 'ALICE' }), turn(bob.personId, { platform: 'slack', id: 'BOB' }, 'TEAM')])
  assert.deepEqual(one, userSections(1))
  assert.deepEqual(two, userSections(2))
  assert.deepEqual(await turn(alice.personId, { platform: 'discord', id: 'ALICE' }, 'OTHER'), userSections(1), 'platform-scoped: any server')
  // A person id that does not match the actor's link, a missing actor, a
  // missing person id (CLI-asserted actors get none) and a foreign site get nothing.
  fs.writeFileSync(calls, '')
  assert.deepEqual(await turn(alice.personId, { platform: 'slack', id: 'BOB' }), [])
  assert.deepEqual(await turn(alice.personId, undefined), [])
  assert.deepEqual(await turn(undefined, { platform: 'discord', id: 'ALICE' }), [])
  assert.deepEqual(await turn('wordpress:/elsewhere:1', { platform: 'discord', id: 'ALICE' }), [])
  assert.deepEqual(await turn('wordpress:/site:abc', { platform: 'discord', id: 'ALICE' }), [])
  assert.equal(readCalls().length, 1, 'only the mismatched link reached WordPress')
  // Unlink between sequential turns: no stale provider cache.
  setState({ links: { 'slack:BOB': 2 } })
  assert.deepEqual(await turn(alice.personId, { platform: 'discord', id: 'ALICE' }), [])
  closed(await person('discord', 'ALICE'))
  assert(readCalls().every((req) => !('acting_user_id' in req) && !('user_id' in req)), 'the adapter never asserts a WordPress user')

  // A leftover `people` block from the old mapping grants nothing.
  fs.writeFileSync(configPath, JSON.stringify({ ...config, people: { 'discord:GUILD:ALICE': { userId: 1, capabilities: ['sessions', 'shell', 'admin'] } } }))
  closed(await person('discord', 'ALICE'))
  fs.writeFileSync(configPath, JSON.stringify({ version: 1 }))
  await assert.rejects(person('discord', 'BOB'), /version 1 with contexts/)

  // Section mapping and malformed responses.
  assert.deepEqual(module.roadieSections([{ name: 'x', layer: 'runtime', content: 'c' }]), [{ id: 'x', content: 'c' }])
  assert.throws(() => module.roadieSections(undefined), /no sections/)
  assert.throws(() => module.roadieSections([{ layer: 'agent', content: 'c' }]), /invalid section/)

  // The helper itself: recognized diagnostics dropped, payload preserved,
  // unrecognized output still rejected rather than scanned for JSON.
  assert.deepEqual(module.parseResolverStdout(PHP_NOTICE + '{"allowed":true}'), { allowed: true })
  assert.deepEqual(module.parseResolverStdout('{"allowed":true}'), { allowed: true })
  assert.deepEqual(module.parseResolverStdout(PHP_NOTICE + '{"sections":[{"id":"a","content":"{nested}"}]}'), { sections: [{ id: 'a', content: '{nested}' }] })
  for (const kind of ['PHP Deprecated', 'Deprecated', 'Warning', 'PHP Warning', 'Notice']) {
    assert.deepEqual(module.parseResolverStdout(`${kind}:  something in file.php on line 1\n\n{"allowed":true}`), { allowed: true })
  }
  assert.deepEqual(module.parseResolverStdout(PHP_NOTICE + '{\n  "allowed": true\n}'), { allowed: true })
  assert.throws(() => module.parseResolverStdout(PHP_NOTICE), /no output/)
  assert.throws(() => module.parseResolverStdout('   '), /no output/)
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
  fs.writeFileSync(slowConfig, JSON.stringify({ version: 1, defaultContext: 's', contexts: { s: { sitePath: '/site', agentSlug: 's', transport: [process.execPath, slow], lookupTimeoutMs: 1000 } } }))
  process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG = slowConfig
  const slowFilters = {}
  module.register({ addFilter: (name, fn) => { slowFilters[name] = fn } })
  await assert.rejects(slowFilters.person({}, { actor: { platform: 'discord', id: 'u1' }, context: { guildId: 'g1' } }), /WordPress context lookup failed: timed out after 1000ms/)

  // The generated PHP is a single public Abilities API call. Run it under PHP
  // against a stub ability: input round-trips, errors exit non-zero.
  const stub = path.join(temp, 'stub.php')
  fs.writeFileSync(stub, `<?php
class WP_Error { function __construct(public $c, public $m) {} function get_error_code() { return $this->c; } function get_error_message() { return $this->m; } }
function is_wp_error($v) { return $v instanceof WP_Error; }
function wp_json_encode($v, $f = 0) { return json_encode($v, $f); }
function wp_get_ability($name) { return getenv('NO_ABILITY') ? null : new class($name) { function __construct(public $name) {} function execute($in) { return getenv('FAIL') ? new WP_Error('ability_invalid_input', 'bad') : array('name' => $this->name, 'in' => $in, 'sections' => array(array('name' => 'S'))); } }; }
eval(file_get_contents(getenv('SNIPPET')));
`)
  const runPhp = (snippet, env = {}) => {
    fs.writeFileSync(path.join(temp, 'snippet.php'), snippet)
    return execFileSync('php', [stub], { env: { ...process.env, SNIPPET: path.join(temp, 'snippet.php'), ...env }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  }
  const input = { agent_slug: 'franklin', platform: 'discord', actor_id: "O'Brien/ü", event: 'turn' }
  assert.deepEqual(JSON.parse(runPhp(module.abilityPhp(input))), { name: module.ABILITY, in: input, sections: [{ name: 'S' }] })
  assert.deepEqual(JSON.parse(runPhp(module.abilityPhp(input, { withSections: false }))).sections, [])
  assert.throws(() => runPhp(module.abilityPhp(input), { FAIL: '1' }), /ability_invalid_input: bad/)
  assert.throws(() => runPhp(module.abilityPhp(input), { NO_ABILITY: '1' }), /not registered/)
  console.log('PASS: resolve-chat-person adapter: platform-scoped links (server moves need no config), seat tiers from the agent access role (admin unrestricted, operator/viewer restricted, denied/unlinked rejected), actorless agent context with no_actor, isolated concurrent user context, unlinked and asserted actor rejection, convention files skipped, PHP-notice stdout tolerated')
} finally {
  delete process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG
  fs.rmSync(temp, { recursive: true, force: true })
}
