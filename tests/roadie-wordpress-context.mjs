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
fs.writeFileSync(wp, `import fs from 'node:fs'; const noise=${JSON.stringify(PHP_NOTICE)}; const args=process.argv.slice(2); const code=args[args.indexOf('eval')+1]; const match=code.match(/\\$args=array\\('([^']+)'\\)/); const req=JSON.parse(Buffer.from(match[1],'base64')); fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify(req)+'\\n'); process.stdout.write(noise); process.stdout.write(JSON.stringify(req.operation==='person'?{allowed:req.user_id===1||req.user_id===2}:{sections:[{id:req.event==='turn'?'user':'shared',content:req.event==='turn'?'USER_'+req.user_id:'SHARED'}]}));`)
const config = {
  version: 1, defaultContext: 'franklin',
  contexts: { franklin: { sitePath: '/site', agentSlug: 'franklin', transport: [process.execPath, wp] } },
  people: { 'discord:GUILD:ALICE': { userId: 1, capabilities: ['sessions'] }, 'slack:TEAM:BOB': { userId: 2, capabilities: ['sessions'] } },
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
  const shared = await filters.context_sections([], { event: 'session_start', contextId: 'franklin' })
  assert.deepEqual(shared, [{ id: 'shared', content: 'SHARED' }])
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
  console.log('PASS: isolated concurrent user context, explicit scoped identity, unmapped and asserted actor rejection, PHP-notice stdout tolerated')
} finally {
  delete process.env.WP_CODING_AGENTS_ROADIE_CONTEXT_CONFIG
  fs.rmSync(temp, { recursive: true, force: true })
}
