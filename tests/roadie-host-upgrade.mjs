// tests/roadie-host-upgrade.mjs — the Roadie host_upgrade plugin starts the
// self-upgrade command and reports its result. sudo is faked on PATH.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'roadie-host-upgrade-'))
const plugin = path.resolve(import.meta.dirname, '../bridges/roadie/roadie-plugins/host-upgrade.mjs')
const bin = path.join(temp, 'wp-coding-agents-upgrade')
const calls = path.join(temp, 'calls')
const localPlist = path.join(temp, 'com.wp.roadie-upgrade.plist')
const localConfig = path.join(temp, 'roadie-upgrade.json')

fs.writeFileSync(bin, '#!/bin/sh\n')
fs.chmodSync(bin, 0o755)
fs.mkdirSync(path.join(temp, 'path'))
// Fake sudo: records argv, exits with $FAKE_EXIT.
fs.writeFileSync(path.join(temp, 'path', 'sudo'), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${calls}'\necho "$FAKE_OUTPUT"\nexit "\${FAKE_EXIT:-0}"\n`)
fs.chmodSync(path.join(temp, 'path', 'sudo'), 0o755)
fs.writeFileSync(path.join(temp, 'path', 'launchctl'), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${calls}'\nif [ "$1" = print ]; then echo "$FAKE_PRINT"; exit "\${FAKE_PRINT_EXIT:-0}"; fi\necho "$FAKE_OUTPUT"\nexit "\${FAKE_EXIT:-0}"\n`)
fs.chmodSync(path.join(temp, 'path', 'launchctl'), 0o755)
process.env.PATH = `${path.join(temp, 'path')}:${process.env.PATH}`

async function load(binPath, configPath = localConfig) {
  process.env.WP_CODING_AGENTS_UPGRADE_BIN = binPath
  process.env.ROADIE_LOCAL_UPGRADE_CONFIG = configPath
  const filters = {}
  const module = await import(`${pathToFileURL(plugin).href}?t=${Math.random()}`)
  module.register({ addFilter: (name, fn) => { filters[name] = fn } })
  return filters.host_upgrade
}

try {
  assert.equal(await load(path.join(temp, 'missing')), undefined, 'no command: no handler registered')

  fs.writeFileSync(localConfig, JSON.stringify({ plist: localPlist, label: 'com.wp.roadie-upgrade', log: '/tmp/roadie-upgrade.log', state: '/tmp/roadie-state.json' }))
  assert.equal(await load(path.join(temp, 'missing')), undefined, 'local handler requires plist')
  fs.writeFileSync(localPlist, '')
  const localFilter = await load(path.join(temp, 'missing'))
  assert.equal(typeof localFilter, 'function', 'local handler registers when plist exists')
  let localHandler = localFilter(null, {})
  process.env.FAKE_PRINT = 'state = waiting'
  process.env.FAKE_EXIT = '0'
  let localResult = await localHandler()
  assert.equal(localResult.ok, true)
  assert.match(localResult.message, /pinned on main/)
  assert.match(localResult.message, /roadie-upgrade\.log/)
  assert.match(fs.readFileSync(calls, 'utf8'), /kickstart gui\/\d+\/com\.wp\.roadie-upgrade/)

  process.env.FAKE_PRINT = 'state = running'
  localResult = await localHandler()
  assert.equal(localResult.ok, false)
  assert.match(localResult.message, /already running/)
  process.env.FAKE_PRINT = 'state = waiting'
  process.env.FAKE_EXIT = '1'
  process.env.FAKE_OUTPUT = 'kickstart denied'
  localResult = await localHandler()
  assert.equal(localResult.ok, false)
  assert.match(localResult.message, /kickstart denied/)

  fs.writeFileSync(calls, '')
  const filter = await load(bin)
  const handler = filter(null, {})
  assert.equal(typeof handler, 'function')

  process.env.FAKE_EXIT = '0'
  let result = await handler({ trigger: 'command' })
  assert.equal(result.ok, true)
  assert.match(result.message, /Upgrade started from main/)
  assert.equal(fs.readFileSync(calls, 'utf8').trim(), `-n ${bin} start`, 'runs exactly sudo -n <bin> start')

  process.env.FAKE_EXIT = '3'
  result = await handler({ trigger: 'cli' })
  assert.deepEqual([result.ok, /already running/.test(result.message)], [false, true])

  process.env.FAKE_EXIT = '1'
  process.env.FAKE_OUTPUT = 'sudo: a password is required'
  result = await handler({ trigger: 'cli' })
  assert.equal(result.ok, false)
  assert.match(result.message, /password is required/)

  console.log('PASS: tests/roadie-host-upgrade.mjs')
} finally {
  fs.rmSync(temp, { recursive: true, force: true })
}
