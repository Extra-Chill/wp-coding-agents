// #787: loadRuntimeApi must resolve Roadie's runtime modules from the managed
// install layout — a symlinked `bin/roadie` entry pointing at the package's
// `bin.js`, with the modules in `dist/` — without the stub env override.
// Optional: set ROADIE_INSTALLED_ENTRY to also check a real install.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const { loadRuntimeApi, resolveRuntimeDir } = await import(path.join(here, '..', 'bridges/roadie/roadie-plugins/wordpress-platform.mjs'))

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'wpca-787-'))
try {
  const pkg = path.join(temp, 'lib/node_modules/@extrachill/roadie')
  const dist = path.join(pkg, 'dist')
  fs.mkdirSync(path.join(dist, 'session-handler'), { recursive: true })
  fs.writeFileSync(path.join(pkg, 'bin.js'), "import './dist/bin.js'\n")
  for (const name of ['database.js', 'channel-policy.js', 'conversation-intake.js', 'hrana-server.js']) {
    fs.writeFileSync(path.join(dist, name), `export const ${name.replace(/[^a-z]/g, '_')} = true\n`)
  }
  fs.writeFileSync(path.join(dist, 'session-handler/thread-session-runtime.js'), 'export function getOrCreateRuntime() { return "rt" }\n')
  fs.mkdirSync(path.join(temp, 'bin'))
  const link = path.join(temp, 'bin/roadie')
  fs.symlinkSync(path.join(pkg, 'bin.js'), link)

  assert.equal(resolveRuntimeDir(link), fs.realpathSync(dist), 'a symlinked bin/roadie resolves to the package dist/')
  assert.equal(resolveRuntimeDir(path.join(dist, 'cli.js')), dist, 'an entry inside dist/ resolves to dist/')
  const api = await loadRuntimeApi({}, ['node', link])
  assert.equal(typeof api.getOrCreateRuntime, 'function', 'runtime API loads through the symlinked entry')
  assert.throws(() => resolveRuntimeDir(path.join(temp, 'nowhere/roadie')), /Cannot locate the Roadie runtime modules/)

  if (process.env.ROADIE_INSTALLED_ENTRY) {
    const real = await loadRuntimeApi({}, ['node', process.env.ROADIE_INSTALLED_ENTRY])
    for (const fn of ['getOrCreateRuntime', 'resolveConversationIntake', 'getThreadSession']) assert.equal(typeof real[fn], 'function', `installed Roadie exposes ${fn}`)
    console.log(`  ok   installed Roadie at ${process.env.ROADIE_INSTALLED_ENTRY}`)
  }
  console.log('PASS: wordpress platform resolves Roadie runtime modules through the managed symlinked entrypoint')
} finally {
  fs.rmSync(temp, { recursive: true, force: true })
}
