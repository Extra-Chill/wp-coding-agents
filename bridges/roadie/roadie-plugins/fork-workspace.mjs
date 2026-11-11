// Homeboy owns Git worktree allocation, registration and lifecycle. Roadie
// consumes only the resulting directory binding. A site-root conversation's
// repository comes from Homeboy's indexed active-task ownership.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'

function run(command, args, cwd) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { cwd, timeout: 120_000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) { reject(new Error(`${command} failed: ${stderr.trim() || error.message}`, { cause: error })); return }
      resolve(stdout.trim())
    })
  })
}

async function commonDirectory(directory) {
  const common = await run('git', ['rev-parse', '--git-common-dir'], directory)
  return fs.realpathSync(path.resolve(directory, common))
}

async function checkoutFor(location) {
  if (typeof location !== 'string' || !path.isAbsolute(location)) return null
  let directory = location
  while (!fs.existsSync(directory)) {
    const parent = path.dirname(directory)
    if (parent === directory) return null
    directory = parent
  }
  if (!fs.statSync(directory).isDirectory()) directory = path.dirname(directory)
  const root = await run('git', ['rev-parse', '--show-toplevel'], directory).catch(() => null)
  if (!root) return null
  return { directory: fs.realpathSync(root), common: await commonDirectory(root) }
}

async function activeOwner(command, request) {
  if (!request.sourceSessionId) return null
  const context = `roadie:session:${request.sourceSessionId}`
  const response = JSON.parse(await run(command, ['agent-task', 'active-scope', '--context', context], request.sourceDirectory))
  const scope = response.data
  if (response.success !== true || scope?.schema !== 'homeboy/agent-task-active-scope/v1' || scope.caller_context !== context || !Array.isArray(scope.workspaces) || !Array.isArray(scope.pending_run_ids)) return null
  if (scope.pending_run_ids.length) return null
  if (!scope.workspaces.length) return null
  for (const owner of scope.workspaces) {
    if (!owner || typeof owner.repository !== 'string' || !owner.repository || typeof owner.working_directory !== 'string' || !path.isAbsolute(owner.working_directory) || !Array.isArray(owner.run_ids) || !owner.run_ids.length || owner.run_ids.some((id) => typeof id !== 'string' || !id) || !fs.existsSync(owner.working_directory) || !fs.statSync(owner.working_directory).isDirectory()) return null
  }
  if (scope.workspaces.length === 1) return scope.workspaces[0]
  // A coordinator can own several independent branches of one repository.
  // Its repository snapshot is the primary checkout's committed HEAD, rather
  // than any one worker branch. Git proves the shared repository identity.
  const commons = await Promise.all(scope.workspaces.map((owner) => commonDirectory(owner.working_directory)))
  if (new Set(commons).size !== 1) return null
  const primary = await checkoutFor(path.dirname(commons[0]))
  if (!primary || primary.common !== commons[0]) return null
  return {
    repository: scope.workspaces[0].repository,
    working_directory: primary.directory,
    run_ids: scope.workspaces.flatMap((owner) => owner.run_ids),
  }
}

export function register(roadie) {
  const configPath = process.env.WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG ?? fileURLToPath(new URL('../fork-workspaces.json', import.meta.url))
  roadie.addFilter('fork_workspace', (_provider, request) => (async () => {
    if (_provider) return _provider
    const config = fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath, 'utf8')) : null
    const command = config?.homeboyCommand ?? 'homeboy'
    const source = await checkoutFor(request.sourceDirectory)
    // A non-Git conversation already runs safely in its shared source directory.
    // Ownership discovery is best-effort; it must never cancel that ordinary fork.
    const owner = source ? null : await activeOwner(command, request).catch(() => null)
    const checkout = source ?? await checkoutFor(owner?.working_directory).catch(() => null)
    if (!checkout) return null
    // A repository path is already a native lifecycle handle. Component
    // registration is unnecessary and must not be a user-facing fork step.
    // Preserve an explicitly configured host allowlist without consulting the
    // entire component registry or changing the source checkout's files.
    if (config?.projects !== undefined) {
      if (config.version !== 1 || !Array.isArray(config.projects)) throw new Error('Invalid fork workspace host configuration')
      const permitted = await Promise.all(config.projects.map(async (project) => {
        const allowed = await checkoutFor(project.directory)
        return allowed?.common === checkout.common
      }))
      if (!permitted.some(Boolean)) throw new Error('This repository is outside the host\'s configured fork scope; no workspace was allocated.')
    }
    return {
      async provision(input) {
        if (!/^[a-f0-9-]{36}$/.test(input.requestId)) return new Error('Invalid fork workspace request identity')
        const base = await run('git', ['rev-parse', 'HEAD'], checkout.directory)
        const branch = `roadie/fork-${input.requestId}`
        const args = ['worktree', 'create', checkout.directory, '--branch', branch, '--from', base, '--run-id', `roadie-fork-${input.requestId}`, '--cleanup-policy', 'preserve-on-failure']
        const response = JSON.parse(await run(command, args, checkout.directory))
        const record = response.data?.record
        if (response.success !== true || !record || typeof record.worktree_path !== 'string' || !path.isAbsolute(record.worktree_path) || typeof record.id !== 'string' || record.branch !== branch) return new Error('Homeboy did not return a verified fork worktree binding')
        // Git is the ground truth for the checkout Homeboy returned. Never
        // copy dirty source files or silently select a different base ref.
        const actual = await run('git', ['rev-parse', 'HEAD'], record.worktree_path)
        if (actual !== base) return new Error('Homeboy fork workspace does not match the requested committed base')
        return { workingDirectory: record.worktree_path, projectDirectory: checkout.directory, label: branch, kind: 'git-worktree', workspaceId: record.id, baseRef: base }
      },
    }
  })().catch((cause) => cause instanceof Error ? cause : new Error('Could not resolve the coding repository; the fork was not started.', { cause })))
  roadie.addAction('fork_workspace_abandoned', async ({ request, binding }) => {
    if (!binding.workspaceId) return
    const config = fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath, 'utf8')) : null
    // Retain evidence and let Homeboy's cleanup policy own later removal.
    await run(config?.homeboyCommand ?? 'homeboy', ['worktree', 'finalize', binding.workspaceId, '--owner-run-ref', `roadie-fork-${request.requestId}`, '--disposition', 'failed'], binding.projectDirectory)
  })
}
