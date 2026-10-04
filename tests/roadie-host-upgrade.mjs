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

fs.writeFileSync(bin, '#!/bin/sh\n')
fs.chmodSync(bin, 0o755)
fs.mkdirSync(path.join(temp, 'path'))
// Fake sudo: records argv, exits with $FAKE_EXIT.
fs.writeFileSync(path.join(temp, 'path', 'sudo'), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${calls}'\necho "$FAKE_OUTPUT"\nexit "\${FAKE_EXIT:-0}"\n`)
fs.chmodSync(path.join(temp, 'path', 'sudo'), 0o755)
process.env.PATH = `${path.join(temp, 'path')}:${process.env.PATH}`

async function load(binPath) {
  process.env.WP_CODING_AGENTS_UPGRADE_BIN = binPath
  const filters = {}
  const module = await import(`${pathToFileURL(plugin).href}?t=${Math.random()}`)
  module.register({ addFilter: (name, fn) => { filters[name] = fn } })
  return filters.host_upgrade
}

try {
  assert.equal(await load(path.join(temp, 'missing')), undefined, 'no command: no handler registered')

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
