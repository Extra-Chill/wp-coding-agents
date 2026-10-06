import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { registerRuntimeConfig } from '../bridges/roadie/roadie-plugins/runtime-config.mjs'
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-profile-'))
const original = process.env.DATAMACHINE_SITE_PATH
process.env.DATAMACHINE_SITE_PATH = root
try {
  fs.writeFileSync(path.join(root, 'opencode.json'), JSON.stringify({ plugin: ['./host-plugin.mjs'], provider: { host: { npm: './provider.mjs', models: { source: { name: 'Source runtime' } } } }, model: 'host/source', small_model: 'host/source', permission: { edit: 'deny' }, instructions: ['source-only.md'] }))
  let filter
  registerRuntimeConfig({ addFilter(name, callback) { assert.equal(name, 'opencode_server_config'); filter = callback } })
  const config = await filter({ plugin: ['bridge-plugin'], provider: {}, permission: { edit: 'allow' } })
  assert.equal(config.model, 'host/source')
  assert.equal(config.small_model, 'host/source')
  assert.deepEqual(config.plugin, ['bridge-plugin', path.join(root, 'host-plugin.mjs')])
  assert.equal(config.provider.host.npm, path.join(root, 'provider.mjs'))
  assert.deepEqual(config.permission, { edit: 'allow' }, 'source project permissions must not overwrite unrelated project policy')
  assert.equal(config.instructions, undefined)
  fs.writeFileSync(path.join(root, 'opencode.json'), '{broken')
  assert.ok(await filter({}) instanceof Error)
  console.log('PASS: installation runtime providers/plugins shared with workspace instances; project permission/instruction policy remains local')
} finally {
  if (original === undefined) delete process.env.DATAMACHINE_SITE_PATH
  else process.env.DATAMACHINE_SITE_PATH = original
  fs.rmSync(root, { recursive: true, force: true })
}
