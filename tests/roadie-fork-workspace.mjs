import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'roadie-homeboy-fork-'))
const previous = { ...process.env }
const source = path.join(root, 'fork-fixture')
const home = path.join(root, 'home')
fs.mkdirSync(source)
fs.mkdirSync(home)
for (const key of Object.keys(process.env)) if (key.startsWith('HOMEBOY_')) delete process.env[key]
process.env.HOME = home
process.env.XDG_CONFIG_HOME = path.join(home, '.config')
process.env.XDG_DATA_HOME = path.join(home, '.local/share')
process.env.XDG_STATE_HOME = path.join(home, '.local/state')
const run = (command, args, cwd = source) => execFileSync(command, args, { cwd, encoding: 'utf8', timeout: 120000 })
const git = (...args) => run('git', args)
let allocated = []
try {
  git('init', '-b', 'main')
  fs.writeFileSync(path.join(source, 'committed.txt'), 'base\n')
  git('add', '.')
  git('-c', 'user.name=Roadie Fixture', '-c', 'user.email=fixture@example.org', 'commit', '-m', 'fixture')
  run('homeboy', ['component', 'create', '--local-path', source])
  const configPath = path.join(root, 'fork-workspaces.json')
  fs.writeFileSync(configPath, JSON.stringify({ version: 1, projects: [{ directory: source, component: 'fork-fixture' }] }))
  process.env.WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG = configPath
  fs.writeFileSync(path.join(source, 'dirty-source.txt'), 'uncommitted\n')
  const filters = {}, actions = {}
  const plugin = await import(pathToFileURL(path.resolve(import.meta.dirname, '../bridges/roadie/roadie-plugins/fork-workspace.mjs')))
  delete process.env.OPENCODE_EXPERIMENTAL_WORKSPACES
  plugin.register({ addFilter(name, fn) { filters[name] = fn }, addAction(name, fn) { actions[name] = fn } })
  assert.equal(process.env.OPENCODE_EXPERIMENTAL_WORKSPACES, 'true')
  process.env.OPENCODE_EXPERIMENTAL_WORKSPACES = 'false'
  plugin.register({ addFilter() {}, addAction() {} })
  assert.equal(process.env.OPENCODE_EXPERIMENTAL_WORKSPACES, 'false')
  const base = git('rev-parse', 'HEAD').trim()
  for (let i = 0; i < 2; i++) {
    const request = { requestId: crypto.randomUUID(), projectDirectory: source, sourceDirectory: source, sourceSessionId: 'parent', sourceThreadId: 'thread' }
    const provider = await filters.fork_workspace(null, request)
    assert.equal(provider.defaultMode, undefined)
    const workspace = await provider.provision(request)
    if (workspace instanceof Error) throw workspace
    allocated.push({ workspace, request })
    assert.equal(run('git', ['rev-parse', 'HEAD'], workspace.workingDirectory).trim(), base)
    assert.equal(fs.existsSync(path.join(workspace.workingDirectory, 'dirty-source.txt')), false)
    fs.writeFileSync(path.join(workspace.workingDirectory, 'fork-only.txt'), `fork-${i}\n`)
    assert.equal(fs.existsSync(path.join(source, 'fork-only.txt')), false)
    assert.equal(workspace.kind, 'git-worktree')
    const status = JSON.parse(run('homeboy', ['worktree', 'status', workspace.workspaceId]))
    assert.equal(status.data.record.run_id, `roadie-fork-${request.requestId}`)
  }
  assert.notEqual(allocated[0].workspace.workingDirectory, allocated[1].workspace.workingDirectory)
  assert.equal(fs.readFileSync(path.join(allocated[0].workspace.workingDirectory, 'fork-only.txt'), 'utf8'), 'fork-0\n')
  assert.equal(fs.readFileSync(path.join(allocated[1].workspace.workingDirectory, 'fork-only.txt'), 'utf8'), 'fork-1\n')
  await actions.fork_workspace_abandoned({ binding: allocated[0].workspace, request: allocated[0].request })
  const status = JSON.parse(run('homeboy', ['worktree', 'status', allocated[0].workspace.workspaceId]))
  assert.equal(status.data.record.terminal_disposition, 'failed')
  assert.equal(fs.existsSync(allocated[0].workspace.workingDirectory), true)
  const nonGit = path.join(root, 'site')
  fs.mkdirSync(nonGit)
  assert.equal(await filters.fork_workspace(null, { sourceDirectory: nonGit }), null)
  // A site-root session records successful coding paths in the backend's
  // history. Select the actual checkout, including a worktree at a newer HEAD.
  const active = allocated[1].workspace.workingDirectory
  run('git', ['add', 'fork-only.txt'], active)
  run('git', ['-c', 'user.name=Roadie Fixture', '-c', 'user.email=fixture@example.org', 'commit', '-m', 'active checkout'], active)
  const activeHead = run('git', ['rev-parse', 'HEAD'], active).trim()
  const siteRequest = { requestId: crypto.randomUUID(), sourceDirectory: nonGit, codingPaths: [path.join(source, 'committed.txt'), path.join(active, 'fork-only.txt')] }
  const siteProvider = await filters.fork_workspace(null, siteRequest)
  const siteWorkspace = await siteProvider.provision(siteRequest)
  if (siteWorkspace instanceof Error) throw siteWorkspace
  assert.equal(siteWorkspace.baseRef, activeHead)
  assert.equal(run('git', ['rev-parse', 'HEAD'], siteWorkspace.workingDirectory).trim(), activeHead)
  assert.equal(fs.readFileSync(path.join(siteWorkspace.workingDirectory, 'fork-only.txt'), 'utf8'), 'fork-1\n')
  assert.equal(fs.existsSync(path.join(nonGit, '.git')), false)
  // Nested forks trust their bound checkout, not inherited parent scopes.
  const nestedProvider = await filters.fork_workspace(null, { sourceDirectory: siteWorkspace.workingDirectory, codingPaths: [source, root] })
  assert.equal(typeof nestedProvider.provision, 'function')
  // Automatic ownership comes from Homeboy's registry without another config.
  fs.unlinkSync(configPath)
  const automaticProvider = await filters.fork_workspace(null, siteRequest)
  const automaticWorkspace = await automaticProvider.provision({ ...siteRequest, requestId: crypto.randomUUID() })
  if (automaticWorkspace instanceof Error) throw automaticWorkspace
  assert.equal(automaticWorkspace.baseRef, activeHead)
  // Multiple coding repositories are explicit ambiguity, never last-write wins.
  const other = path.join(root, 'other')
  fs.mkdirSync(other)
  run('git', ['init', '-b', 'main'], other)
  const ambiguous = await filters.fork_workspace(null, { sourceDirectory: nonGit, codingPaths: [source, other] })
  assert.ok(ambiguous instanceof Error)
  assert.match(ambiguous.message, /multiple repositories/)
  const unowned = await filters.fork_workspace(null, { sourceDirectory: nonGit, codingPaths: [other] })
  assert.ok(unowned instanceof Error)
  assert.match(unowned.message, /no Homeboy owner/)
  console.log('PASS: automatic registry ownership and site-root coding scope allocate real isolated worktrees at the active checkout commit, preserve dirty source work, reject ambiguity and retain failure evidence')
} finally {
  process.env = previous
  // All fixtures live under the test-owned temporary root and isolated HOME.
  fs.rmSync(root, { recursive: true, force: true })
}
