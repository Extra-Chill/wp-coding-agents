#!/usr/bin/env node
// bridges/roadie/accounts.mjs — move subscription accounts between OpenCode
// and subrouter, the account router Roadie uses.
//
//   import  OpenCode → subrouter. Runs during the Kimaki → Roadie migration,
//           after Kimaki stopped: the rotation pools (<provider>-oauth-accounts.json)
//           and single logins (auth.json) become subrouter pools, in the same
//           order with the same active account.
//   export  subrouter → OpenCode. The rollback: after Roadie has refreshed a
//           token, the copy Kimaki kept is stale (refresh tokens rotate on use).
//
// Never run either direction while both sides are live; whichever refreshes
// first invalidates the other's refresh token.
//
// Usage (as the service user):
//   node accounts.mjs import --opencode-data <dir> --roadie-package <dir> [--presets-json <json>]
//   node accounts.mjs export --opencode-data <dir> --roadie-package <dir>
//
// subrouter's own store API does the reading, writing and locking, resolved
// from the installed Roadie package so the format matches the pinned release.
// Output names providers and counts only, never tokens.
//
// --presets-json <json> (import only): a JSON object of subrouter presets,
// { "<name>": ["<provider>/<model>", ...] }, served to OpenCode as
// subrouter/<name>. A preset subrouter already has is left as it is, so edits
// made with `subrouter preset` survive upgrades.

import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

// OpenCode provider id → subrouter provider id.
const PROVIDERS = {
  anthropic: 'anthropic',
  openai: 'openai',
  xai: 'xai',
  'opencode-go': 'opencode-go',
  'github-copilot': 'github-copilot',
  'zai-coding-plan': 'zai',
}
// Providers whose OpenCode rotation pool lives in its own file.
const POOL_FILES = {
  anthropic: 'anthropic-oauth-accounts.json',
  openai: 'openai-oauth-accounts.json',
  xai: 'xai-oauth-accounts.json',
}

function usage(message) {
  if (message) console.error(`accounts: ${message}`)
  console.error('usage: accounts.mjs import|export --opencode-data <dir> --roadie-package <dir>')
  process.exit(2)
}

const [mode, ...rest] = process.argv.slice(2)
const options = {}
for (let i = 0; i < rest.length; i += 2) {
  if (!rest[i]?.startsWith('--') || rest[i + 1] === undefined) usage(`bad argument ${rest[i] ?? ''}`)
  options[rest[i].slice(2)] = rest[i + 1]
}
if (!['import', 'export'].includes(mode)) usage(`unknown mode ${mode ?? ''}`)
if (!options['opencode-data'] || !options['roadie-package']) usage('missing --opencode-data or --roadie-package')

const dataDir = options['opencode-data']
const subrouter = await loadSubrouter(options['roadie-package'])

if (mode === 'import') await importAccounts()
else await exportAccounts()

async function loadSubrouter(roadiePackage) {
  const manifest = path.join(roadiePackage, 'package.json')
  if (!fs.existsSync(manifest)) usage(`no Roadie package at ${roadiePackage}`)
  let entry
  try {
    entry = createRequire(manifest).resolve('@subrouter/cli')
  } catch {
    usage(`@subrouter/cli is not installed with Roadie at ${roadiePackage}`)
  }
  const module = await import(pathToFileURL(entry).href)
  for (const name of ['loadAccounts', 'saveAccounts', 'withStoreLock', 'upsertAccount', 'loadPresets', 'savePreset']) {
    if (typeof module[name] !== 'function') usage(`@subrouter/cli does not export ${name}; Roadie and this script disagree`)
  }
  return module
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dataDir, file), 'utf8'))
  } catch {
    return null
  }
}

function storedAccount(entry, now) {
  if (!entry || typeof entry !== 'object') return null
  const type = entry.type === 'api' ? 'api' : entry.type === 'oauth' ? 'oauth' : null
  if (!type) return null
  if (type === 'api' && typeof entry.key !== 'string') return null
  if (type === 'oauth' && typeof entry.refresh !== 'string') return null
  const account = { type, addedAt: entry.addedAt ?? now, lastUsed: entry.lastUsed ?? now }
  for (const key of ['refresh', 'access', 'expires', 'key', 'email', 'accountId']) {
    if (entry[key] !== undefined) account[key] = entry[key]
  }
  return account
}

function sameAccount(a, b) {
  return Boolean(
    (a.refresh && a.refresh === b.refresh) ||
      (a.key && a.key === b.key) ||
      (a.accountId && a.accountId === b.accountId) ||
      (a.email && b.email && a.email.toLowerCase() === b.email.toLowerCase()),
  )
}

async function importAccounts() {
  const now = Date.now()
  const auth = readJson('auth.json') ?? {}
  const summary = []
  await subrouter.withStoreLock(async () => {
    const store = await subrouter.loadAccounts()
    for (const [opencodeId, subrouterId] of Object.entries(PROVIDERS)) {
      // A pool subrouter already holds is newer than anything OpenCode kept:
      // never overwrite it with older tokens.
      if (store.providers[subrouterId]?.accounts?.length) {
        summary.push(`${subrouterId}: kept existing subrouter pool`)
        continue
      }
      const pool = { activeIndex: 0, accounts: [] }
      const file = POOL_FILES[opencodeId] && readJson(POOL_FILES[opencodeId])
      for (const entry of file?.accounts ?? []) {
        const account = storedAccount(entry, now)
        if (account) pool.accounts.push(account)
      }
      if (Number.isInteger(file?.activeIndex) && file.activeIndex < pool.accounts.length) {
        pool.activeIndex = file.activeIndex
      }
      // The single login in auth.json is the active account. When the pool
      // also holds it, keep whichever copy expires later.
      const single = storedAccount(auth[opencodeId], now)
      if (single) {
        const index = pool.accounts.findIndex((account) => sameAccount(account, single))
        if (index < 0) {
          pool.accounts.push(single)
          if (!file) pool.activeIndex = pool.accounts.length - 1
        } else if ((single.expires ?? 0) > (pool.accounts[index].expires ?? 0)) {
          pool.accounts[index] = { ...pool.accounts[index], ...single, addedAt: pool.accounts[index].addedAt }
        }
      }
      if (pool.accounts.length === 0) continue
      store.providers[subrouterId] = pool
      summary.push(`${subrouterId}: ${pool.accounts.length} account(s), active #${pool.activeIndex + 1}`)
    }
    await subrouter.saveAccounts(store)
  })
  console.log(summary.length ? summary.join('\n') : 'No OpenCode accounts to import.')
  if (options['presets-json']) await importPresets(options['presets-json'])
}

async function importPresets(json) {
  let wanted
  try {
    wanted = JSON.parse(json)
  } catch (error) {
    usage(`invalid presets JSON: ${error.message}`)
  }
  const existing = (await subrouter.loadPresets()).presets ?? {}
  for (const [name, models] of Object.entries(wanted)) {
    if (!Array.isArray(models) || models.some((entry) => typeof entry !== 'string' || !entry.includes('/'))) {
      usage(`preset ${name} must be a list of provider/model ids`)
    }
    if (existing[name]) {
      console.log(`preset ${name}: kept existing`)
      continue
    }
    await subrouter.savePreset({ name, models })
    console.log(`preset ${name}: ${models.join(' -> ')}`)
  }
}

function writeSecretJson(file, value) {
  const target = path.join(dataDir, file)
  if (fs.existsSync(target)) fs.copyFileSync(target, `${target}.before-roadie-rollback`)
  const temp = `${target}.tmp-${process.pid}`
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  fs.renameSync(temp, target)
}

async function exportAccounts() {
  const store = await subrouter.withStoreLock(() => subrouter.loadAccounts())
  const auth = readJson('auth.json') ?? {}
  const summary = []
  for (const [opencodeId, subrouterId] of Object.entries(PROVIDERS)) {
    const pool = store.providers[subrouterId]
    if (!pool?.accounts?.length) continue
    const active = pool.accounts[pool.activeIndex] ?? pool.accounts[0]
    if (POOL_FILES[opencodeId]) {
      const previous = readJson(POOL_FILES[opencodeId])
      writeSecretJson(POOL_FILES[opencodeId], {
        version: previous?.version ?? 1,
        activeIndex: Math.min(pool.activeIndex, pool.accounts.length - 1),
        accounts: pool.accounts,
      })
    }
    auth[opencodeId] = active.type === 'api'
      ? { type: 'api', key: active.key }
      : { type: 'oauth', refresh: active.refresh, access: active.access, expires: active.expires }
    summary.push(`${opencodeId}: ${pool.accounts.length} account(s), active #${pool.activeIndex + 1}`)
  }
  if (summary.length) writeSecretJson('auth.json', auth)
  console.log(summary.length ? summary.join('\n') : 'No subrouter accounts to export.')
}
