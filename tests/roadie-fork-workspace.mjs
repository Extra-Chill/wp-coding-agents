import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'roadie-active-owner-'))
const previous = { ...process.env }
const realHomeboy = process.env.HOMEBOY_FORK_TEST_COMMAND ?? 'homeboy'
const source = path.join(root, 'fork-fixture')
const home = path.join(root, 'host-home')
const site = path.join(root, 'site')
for (const directory of [source, home, site]) fs.mkdirSync(directory)
// Homeboy 0.422.0 (Extra-Chill/homeboy#15859) removed `agent-task submit`, and
// queued ownership is controller-internal now: every current CLI verb either
// executes the plan or refuses queue-only admission. The fixture therefore
// seeds active-scope ownership through its own wrapper command, which answers
// the submit/cancel/active-scope surface from a JSON store and delegates every
// other invocation to the real Homeboy binary. Worktree allocation, finalize,
// and status — the production code under test — stay entirely real.
const scopeStore = path.join(root, 'active-scope-store.json')
const wrapperPath = path.join(root, 'fork-homeboy-wrapper.mjs')
fs.writeFileSync(wrapperPath, `#!/usr/bin/env node
import fs from 'node:fs'
import { spawnSync } from 'node:child_process'
const args = process.argv.slice(2)
const readStore = () => { try { return JSON.parse(fs.readFileSync(process.env.ROADIE_FORK_TEST_SCOPE_STORE, 'utf8')) } catch { return {} } }
const envelope = (operation, data) => { process.stdout.write(JSON.stringify({ schema: 'homeboy/command-result/v3', command: 'agent-task', operation, success: true, exit_code: 0, data }) + '\\n') }
if (args[0] === 'agent-task') {
  if (args[1] === 'submit' && args.includes('--run-id') && args.includes('--plan')) {
    const plan = JSON.parse(args[args.indexOf('--plan') + 1])
    const workspace = plan.metadata?.caller_workspace ?? null
    const store = readStore()
    const entries = store[process.env.HOMEBOY_CALLER_CONTEXT ?? ''] ?? []
    entries.push({ run_id: args[args.indexOf('--run-id') + 1], repository: workspace?.repository ?? null, working_directory: workspace?.working_directory ?? null })
    store[process.env.HOMEBOY_CALLER_CONTEXT ?? ''] = entries
    fs.writeFileSync(process.env.ROADIE_FORK_TEST_SCOPE_STORE, JSON.stringify(store))
    envelope('submit', { submitted: true })
    process.exit(0)
  }
  if (args[1] === 'active-scope' && args.includes('--context')) {
    const context = args[args.indexOf('--context') + 1]
    const entries = readStore()[context] ?? []
    const workspaces = entries.filter((entry) => entry.working_directory).map((entry) => ({ repository: entry.repository, working_directory: entry.working_directory, run_ids: [entry.run_id] }))
    const pending_run_ids = entries.filter((entry) => !entry.working_directory).map((entry) => entry.run_id)
    envelope('active-scope', { schema: 'homeboy/agent-task-active-scope/v1', caller_context: context, workspaces, pending_run_ids })
    process.exit(0)
  }
  if (args[1] === 'cancel' && args.length === 3 && !args[2].startsWith('-')) {
    const store = readStore()
    for (const entries of Object.values(store)) {
      const index = entries.findIndex((entry) => entry.run_id === args[2])
      if (index !== -1) entries.splice(index, 1)
    }
    fs.writeFileSync(process.env.ROADIE_FORK_TEST_SCOPE_STORE, JSON.stringify(store))
    envelope('cancel', { cancellation: { run_id: args[2], accepted: 'cancelled' } })
    process.exit(0)
  }
}
const result = spawnSync(process.env.ROADIE_FORK_TEST_REAL_HOMEBOY ?? 'homeboy', args, { stdio: 'inherit' })
process.exit(result.status ?? 1)
`)
fs.chmodSync(wrapperPath, 0o755)
const command = wrapperPath
for (const key of Object.keys(process.env)) if (key.startsWith('HOMEBOY_')) delete process.env[key]
Object.assign(process.env, { HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), XDG_DATA_HOME: path.join(home, '.local/share'), XDG_STATE_HOME: path.join(home, '.local/state'), ROADIE_FORK_TEST_SCOPE_STORE: scopeStore, ROADIE_FORK_TEST_REAL_HOMEBOY: realHomeboy })
const run = (name, args, cwd = source) => execFileSync(name, args, { cwd, encoding: 'utf8', timeout: 120000 })
const hb = (...args) => JSON.parse(run(command, args))
const git = (...args) => run('git', args)
const session = 'fixture-session'
const context = `roadie:session:${session}`
const request = (directory = site) => ({ requestId: crypto.randomUUID(), sourceDirectory: directory, projectDirectory: site, sourceSessionId: session, sourceThreadId: 'fixture-thread' })
const submit = (id, repository, directory) => {
  process.env.HOMEBOY_CALLER_CONTEXT = context
  const plan = { schema: 'homeboy/agent-task-plan/v1', plan_id: id, tasks: [], metadata: { repo: repository, ...(directory && { caller_workspace: { repository, working_directory: directory } }) } }
  const result = hb('agent-task', 'submit', '--run-id', id, '--plan', JSON.stringify(plan))
  assert.equal(result.success, true)
  delete process.env.HOMEBOY_CALLER_CONTEXT
}
try {
  git('init', '-b', 'main')
  fs.writeFileSync(path.join(source, 'committed.txt'), 'base\n')
  git('add', '.')
  git('-c', 'user.name=Roadie Fixture', '-c', 'user.email=fixture@example.org', 'commit', '-m', 'fixture')
  const configPath = path.join(root, 'fork-workspaces.json')
  fs.writeFileSync(configPath, JSON.stringify({ version: 1, homeboyCommand: command }))
  process.env.WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG = configPath
  const filters = {}, actions = {}
  const plugin = await import(pathToFileURL(path.resolve(import.meta.dirname, '../bridges/roadie/roadie-plugins/fork-workspace.mjs')))
  plugin.register({ addFilter(name, fn) { filters[name] = fn }, addAction(name, fn) { actions[name] = fn } })
  // Historical locations are deliberately irrelevant to a non-coding fork.
  assert.equal(await filters.fork_workspace(null, { ...request(), codingPaths: [source] }), null)
  const standalone = request(source)
  const standaloneProvider = await filters.fork_workspace(null, standalone)
  if (standaloneProvider instanceof Error) throw standaloneProvider
  const standaloneBinding = await standaloneProvider.provision(standalone)
  if (standaloneBinding instanceof Error) throw standaloneBinding
  assert.equal(fs.existsSync(path.join(source, 'homeboy.json')), false, 'automatic forks must not add configuration to the source checkout')
  assert.equal(run('git', ['rev-parse', 'HEAD'], standaloneBinding.workingDirectory).trim(), git('rev-parse', 'HEAD').trim())
  fs.writeFileSync(path.join(source, 'dirty-source.txt'), 'uncommitted\n')
  submit('task-A', 'fork-fixture', source)
  const workspaces = []
  const base = git('rev-parse', 'HEAD').trim()
  for (let number = 0; number < 2; number++) {
    const input = request()
    const provider = await filters.fork_workspace(null, input)
    if (provider instanceof Error) throw provider
    const binding = await provider.provision(input)
    if (binding instanceof Error) throw binding
    workspaces.push({ binding, input })
    assert.equal(run('git', ['rev-parse', 'HEAD'], binding.workingDirectory).trim(), base)
    assert.equal(fs.existsSync(path.join(binding.workingDirectory, 'dirty-source.txt')), false)
    fs.writeFileSync(path.join(binding.workingDirectory, 'fork-only.txt'), `fork-${number}\n`)
    assert.equal(fs.existsSync(path.join(source, 'fork-only.txt')), false)
  }
  assert.notEqual(workspaces[0].binding.workingDirectory, workspaces[1].binding.workingDirectory)
  await actions.fork_workspace_abandoned({ request: workspaces[0].input, binding: workspaces[0].binding })
  assert.equal(hb('worktree', 'status', workspaces[0].binding.workspaceId).data.record.terminal_disposition, 'failed')
  // A separately admitted task switches ownership; neither old scope nor
  // completion callbacks may remove a newer active task's checkout.
  const active = workspaces[1].binding.workingDirectory
  run('git', ['add', 'fork-only.txt'], active)
  run('git', ['-c', 'user.name=Roadie Fixture', '-c', 'user.email=fixture@example.org', 'commit', '-m', 'active checkout'], active)
  submit('task-B', 'fork-fixture', active)
  const coordinatorRequest = request()
  const coordinator = await filters.fork_workspace(null, coordinatorRequest)
  if (coordinator instanceof Error) throw coordinator
  const coordinatorBinding = await coordinator.provision(coordinatorRequest)
  if (coordinatorBinding instanceof Error) throw coordinatorBinding
  assert.equal(coordinatorBinding.baseRef, base, 'coordinator snapshot uses the primary committed base, not a worker branch')
  assert.equal(coordinatorBinding.projectDirectory, fs.realpathSync(source))
  assert.notEqual(coordinatorBinding.workingDirectory, active)
  const other = path.join(root, 'other-repository')
  fs.mkdirSync(other)
  run('git', ['init', '-b', 'main'], other)
  run('git', ['-c', 'user.name=Roadie Fixture', '-c', 'user.email=fixture@example.org', 'commit', '--allow-empty', '-m', 'other repository'], other)
  submit('other-task', 'other-repository', other)
  const ambiguous = await filters.fork_workspace(null, request())
  assert.ok(ambiguous instanceof Error)
  assert.match(ambiguous.message, /multiple active repositories/)
  assert.equal(hb('agent-task', 'cancel', 'other-task').success, true)
  assert.equal(hb('agent-task', 'cancel', 'task-A').success, true)
  const owner = hb('agent-task', 'active-scope', '--context', context).data
  assert.equal(owner.workspaces.length, 1)
  assert.equal(owner.workspaces[0].working_directory, active)
  const input = request()
  const provider = await filters.fork_workspace(null, input)
  const binding = await provider.provision(input)
  if (binding instanceof Error) throw binding
  assert.equal(binding.baseRef, run('git', ['rev-parse', 'HEAD'], active).trim())
  assert.equal(hb('agent-task', 'cancel', 'task-B').success, true)
  assert.equal(await filters.fork_workspace(null, request()), null)
  // A repository-bound fork still owns its concrete checkout independently
  // of its parent's task and uses no conversation-derived locations.
  assert.equal(typeof (await filters.fork_workspace(null, request(binding.workingDirectory))).provision, 'function')
  submit('pending-task', 'fork-fixture', null)
  const pending = await filters.fork_workspace(null, request())
  assert.ok(pending instanceof Error)
  assert.match(pending.message, /not finished allocating/)
  const boundRequest = request(binding.workingDirectory)
  const boundProvider = await filters.fork_workspace(null, boundRequest)
  if (boundProvider instanceof Error) throw boundProvider
  const boundFork = await boundProvider.provision(boundRequest)
  if (boundFork instanceof Error) throw boundFork
  assert.equal(boundFork.baseRef, run('git', ['rev-parse', 'HEAD'], binding.workingDirectory).trim())
  assert.notEqual(boundFork.workingDirectory, binding.workingDirectory)
  // A bound checkout is sufficient authority even when task discovery is
  // unavailable; no pending parent can replace the conversation's directory.
  fs.writeFileSync(configPath, JSON.stringify({ version: 1, homeboyCommand: 'fixture-absent-controller' }))
  assert.equal(typeof (await filters.fork_workspace(null, request(binding.workingDirectory))).provision, 'function')
  console.log('PASS: fixture-seeded active ownership across task switch and completion with real Homeboy worktrees; historical activity ignored, ambiguity and pending allocation fail closed')
} finally {
  process.env = previous
  fs.rmSync(root, { recursive: true, force: true })
}
