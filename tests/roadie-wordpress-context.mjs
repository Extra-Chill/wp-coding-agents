import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
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
const linkCalls = path.join(temp, 'link-calls.jsonl')

// Fake WordPress: plays Data Machine's datamachine/resolve-chat-person against
// platform-scoped chat identity links (ChatIdentityLinks) and agent access
// roles (ChatPersonResolver). `old` mimics Data Machine before #3615, which
// denied an actorless request as actor_not_linked with no sections.
fs.writeFileSync(state, JSON.stringify({
  links: { 'discord:ALICE': 1, 'slack:BOB': 2, 'discord:CAROL': 3, 'discord:NOROLE': 4, 'discord:DENIED': 5 },
  roles: { 1: 'admin', 2: 'viewer', 3: 'operator', 4: '' },
  old: false,
}))
// It also plays datamachine/link-chat-identity (ChatIdentityLinks::link): a
// user holds one actor per platform (relinking replaces it), an actor held by
// another user is a chat_identity_conflict, and the user must exist.
fs.writeFileSync(wp, `import fs from 'node:fs'
const args = process.argv.slice(2)
const code = args[args.indexOf('eval') + 1]
const req = JSON.parse(Buffer.from(code.match(/base64_decode\\( '([^']+)'/)[1], 'base64'))
if (code.includes("wp_get_ability( 'datamachine/link-chat-identity' )")) {
  if (!code.includes("'error' => array(")) { process.stderr.write('link must report errors as JSON'); process.exit(1) }
  fs.appendFileSync(${JSON.stringify(linkCalls)}, JSON.stringify({ ...req, argv: args.filter((arg) => arg !== code) }) + '\\n')
  const current = JSON.parse(fs.readFileSync(${JSON.stringify(state)}, 'utf8'))
  const key = req.platform + ':' + req.actor_id
  const fail = (code, message) => { process.stdout.write(${JSON.stringify(PHP_NOTICE)} + JSON.stringify({ error: { code, message } })); process.exit(0) }
  if (![1, 2, 3, 4, 5, 7].includes(req.user_id)) fail('chat_identity_user_not_found', 'WordPress user not found.')
  if (current.links[key] && current.links[key] !== req.user_id) fail('chat_identity_conflict', 'That actor is already linked to another user on this platform.')
  for (const [other, user] of Object.entries(current.links)) if (user === req.user_id && other.startsWith(req.platform + ':')) delete current.links[other]
  current.links[key] = req.user_id
  fs.writeFileSync(${JSON.stringify(state)}, JSON.stringify(current))
  process.stdout.write(JSON.stringify({ success: true, user_id: req.user_id, platform: req.platform, actor_id: req.actor_id }))
  process.exit(0)
}
if (!code.includes("wp_get_ability( 'datamachine/resolve-chat-person' )")) { process.stderr.write('not the ability'); process.exit(1) }
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

  // #765 / roadie#292: self-serve identity linking. A fake site answers
  // /wp-json/wp/v2/users/me for bearer tokens, like WordPress with bearer auth.
  const seen = []
  const userinfo = http.createServer((req, res) => {
    const token = String(req.headers.authorization ?? '').replace(/^Bearer /, '')
    seen.push({ path: req.url, method: req.method, token })
    if (token === 'slow-secret') return
    const json = (status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(typeof body === 'string' ? body : JSON.stringify(body)) }
    if (req.url !== '/wp-json/wp/v2/users/me') return json(404, { code: 'rest_no_route' })
    if (token === 'redirect-secret') { res.writeHead(302, { location: 'https://elsewhere.test/me' }); return res.end() }
    const users = { 'admin-secret': 1, 'nogrant-secret': 7, 'ghost-secret': 99 }
    if (token in users) return json(200, { id: users[token], name: 'someone' })
    if (token === 'err-secret') return json(500, { code: 'oops' })
    if (token === 'junk-secret') return json(200, '<html>not json')
    if (token === 'noid-secret') return json(200, { name: 'no id' })
    return json(401, { code: 'rest_not_logged_in', message: 'You are not currently logged in.' })
  })
  await new Promise((resolve) => userinfo.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${userinfo.address().port}`
  const warnings = []
  const warn = console.warn
  console.warn = (...args) => warnings.push(args.join(' '))
  try {
    const linkConfig = {
      ...config,
      contexts: {
        ...config.contexts,
        franklin: { ...config.contexts.franklin, lookupTimeoutMs: 1000, mcpServers: [{ name: 'site', url: `${origin}/wp-json/extrachill-mcp/v1/mcp` }], selfLink: { server: 'site' } },
      },
    }
    fs.writeFileSync(configPath, JSON.stringify(linkConfig))
    setState({ links: { 'discord:ALICE': 1, 'discord:CAROL': 3 } })
    fs.writeFileSync(linkCalls, '')
    const provider = (channelId = 'C1', actor = { platform: 'discord', id: 'NEWBIE' }) => filters.identity_link_provider(null, { actor, context: { guildId: 'GUILD', channelId } })
    const link = (access, actor = { platform: 'discord', id: 'NEWBIE' }, channelId = 'C1') => filters.link_identity(undefined, { actor, context: { guildId: 'GUILD', channelId }, token: access === undefined ? undefined : { access, refresh: 'refresh-secret' } })
    const readLinkCalls = () => fs.readFileSync(linkCalls, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse)

    // Provider: the named server (Roadie discovers its OAuth server like /connect).
    assert.deepEqual(await provider(), { url: `${origin}/wp-json/extrachill-mcp/v1/mcp`, name: 'site', credential: 'site' })
    // No selfLink on the context (ghost), or no actor: null / the prior value.
    assert.equal(await provider('GHOST'), null)
    assert.equal(await provider('C1', { platform: 'discord' }), null)
    assert.deepEqual(await filters.link_identity(undefined, { actor: { platform: 'discord', id: 'X' }, context: { channelId: 'GHOST' }, token: { access: 'admin-secret' } }), { linked: false, reason: "This site doesn't offer account linking here." })
    assert.equal(readLinkCalls().length, 0)

    // Unlinked person signs in as user 1: the token goes to users/me as a
    // bearer; the verified id (never caller input) is linked, without --user.
    closed(await person('discord', 'NEWBIE'))
    assert.deepEqual(await link('admin-secret'), { linked: true })
    assert.deepEqual(seen.at(-1), { path: '/wp-json/wp/v2/users/me', method: 'GET', token: 'admin-secret' })
    const [linkCall] = readLinkCalls()
    assert.deepEqual(linkCall, { user_id: 1, platform: 'discord', actor_id: 'NEWBIE', argv: ['--path=/site', 'eval', '--allow-root'] })
    const now = await person('discord', 'NEWBIE')
    assert.deepEqual([now.allowed, now.personId], [true, 'wordpress:/site:1'])
    // Linking again as the same user is idempotent.
    assert.deepEqual(await link('admin-secret'), { linked: true })

    // An actor already linked to someone else is refused, and nothing changes.
    const conflict = await link('admin-secret', { platform: 'discord', id: 'CAROL' })
    assert.equal(conflict.linked, false)
    assert.match(conflict.reason, /already linked to a different WordPress account/)
    assert.equal(JSON.parse(fs.readFileSync(state, 'utf8')).links['discord:CAROL'], 3)

    // Linked, but the user holds no agent grant: access is still the grant's call.
    assert.deepEqual(await link('nogrant-secret', { platform: 'slack', id: 'NOGRANT' }), { linked: true })
    closed(await person('slack', 'NOGRANT'))

    // Every failure returns { linked: false, reason } in plain words.
    fs.writeFileSync(linkCalls, '')
    const failures = [
      ['wrong-secret', /didn't accept that sign-in/],
      ['err-secret', /couldn't confirm your sign-in \(HTTP 500\)/],
      ['junk-secret', /didn't name a WordPress account/],
      ['noid-secret', /didn't name a WordPress account/],
      ['redirect-secret', /Couldn't reach the site/],
      ['slow-secret', /didn't answer in time/],
      ['ghost-secret', /refused the link \(chat_identity_user_not_found\)/],
      ['', /did not return a usable token/],
      [undefined, /did not return a usable token/],
    ]
    for (const [access, reason] of failures) {
      const result = await link(access)
      assert.equal(result.linked, false, String(access))
      assert.match(result.reason, reason, String(access))
    }
    assert.match((await link('admin-secret', { platform: 'discord' })).reason, /which chat account/)
    assert.deepEqual(readLinkCalls().map((call) => call.user_id), [99], 'only a verified user id reaches the link ability')
    // The transport failing while recording the link.
    const broken = await module.linkIdentity({ sitePath: '/site', transport: [process.execPath, '-e', 'process.exit(3)'] }, { userinfoUrl: `${origin}/wp-json/wp/v2/users/me` }, { actor: { platform: 'discord', id: 'Z' }, token: { access: 'admin-secret' } })
    assert.deepEqual(broken, { linked: false, reason: "Couldn't record the link on the site. Try again later or ask an admin." })
    // The token never appears in a reason or a log line.
    assert(warnings.length >= 2, 'refusals and transport failures are logged')
    for (const line of warnings) assert(!/secret/.test(line), line)
    for (const [access] of failures) if (access) assert(!JSON.stringify(await link(access)).includes(access))

    // Config validation: https or loopback http, a known server, default URL.
    const base = { mcpServers: [{ name: 'site', url: 'https://auth.example.com/wp-json/extrachill-mcp/v1/mcp' }] }
    assert.deepEqual(module.selfLinkFor({ ...base, selfLink: { server: 'site' } }), { server: { name: 'site', url: 'https://auth.example.com/wp-json/extrachill-mcp/v1/mcp', credential: 'site' }, userinfoUrl: 'https://auth.example.com/wp-json/wp/v2/users/me' })
    assert.equal(module.selfLinkFor({ ...base, selfLink: { server: 'site', userinfoUrl: 'https://id.example.com/me' } }).userinfoUrl, 'https://id.example.com/me')
    assert.equal(module.selfLinkFor({ ...base, selfLink: { server: 'site', userinfoUrl: 'http://id.example.com/me' } }), null)
    assert.equal(module.selfLinkFor({ ...base, selfLink: { server: 'site', userinfoUrl: 'https://u:p@id.example.com/me' } }), null)
    assert.equal(module.selfLinkFor({ ...base, selfLink: { server: 'other' } }), null)
    assert.equal(module.selfLinkFor({ ...base, selfLink: true }), null)
    assert.equal(module.selfLinkFor(base), null)
    assert.equal(module.selfLinkFor(null), null)
    await assert.rejects(module.fetchUserId('http://example.com/me', 'x'), /misconfigured/)
  } finally {
    console.warn = warn
    userinfo.closeAllConnections()
    await new Promise((resolve) => userinfo.close(resolve))
    fs.writeFileSync(configPath, JSON.stringify(config))
  }

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
  assert.deepEqual(JSON.parse(runPhp(module.abilityPhp(module.ABILITY, input))), { name: module.ABILITY, in: input, sections: [{ name: 'S' }] })
  assert.deepEqual(JSON.parse(runPhp(module.abilityPhp(module.ABILITY, input, { withSections: false }))).sections, [])
  assert.throws(() => runPhp(module.abilityPhp(module.ABILITY, input), { FAIL: '1' }), /ability_invalid_input: bad/)
  assert.throws(() => runPhp(module.abilityPhp(module.ABILITY, input), { NO_ABILITY: '1' }), /not registered/)
  // The link call takes any ability name and reports a refusal as JSON, exit 0.
  const linkInput = { user_id: 1, platform: 'discord', actor_id: 'NEWBIE' }
  assert.deepEqual(JSON.parse(runPhp(module.abilityPhp(module.LINK_ABILITY, linkInput, { errorsAsJson: true }))), { name: module.LINK_ABILITY, in: linkInput, sections: [{ name: 'S' }] })
  assert.deepEqual(JSON.parse(runPhp(module.abilityPhp(module.LINK_ABILITY, linkInput, { errorsAsJson: true }), { FAIL: '1' })), { error: { code: 'ability_invalid_input', message: 'bad' } })
  assert.throws(() => module.abilityPhp("x'); evil(); ('", {}), /Invalid ability name/)
  console.log('PASS: resolve-chat-person adapter: platform-scoped links (server moves need no config), seat tiers from the agent access role (admin unrestricted, operator/viewer restricted, denied/unlinked rejected), actorless agent context with no_actor, isolated concurrent user context, unlinked and asserted actor rejection, convention files skipped, PHP-notice stdout tolerated, self-serve link (verified users/me id, conflict refused, plain reasons, no token leaks)')
} finally {
  delete process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG
  fs.rmSync(temp, { recursive: true, force: true })
}
