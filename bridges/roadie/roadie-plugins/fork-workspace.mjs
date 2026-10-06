// Homeboy owns Git worktree allocation, registration and lifecycle. Roadie
// consumes only the resulting directory binding. A site-root conversation's
// repository comes from successful coding activity, never conversation prose.
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

async function projectsFor(config, command, cwd) {
  if (config) {
    if (config.version !== 1 || !Array.isArray(config.projects)) throw new Error('Use version 1 and a projects array in fork-workspaces.json')
    return config.projects.filter((project) => typeof project.directory === 'string' && path.isAbsolute(project.directory) && typeof project.component === 'string' && project.component)
  }
  const response = JSON.parse(await run(command, ['component', 'list'], cwd))
  if (response.success !== true || !Array.isArray(response.data?.entities)) throw new Error('Homeboy component ownership is unavailable; the fork was not started.')
  // Repository-root components own worktrees. Subdirectory components in a
  // monorepo do not create a second competing repository owner.
  const projects = []
  for (const component of response.data.entities) {
    if (typeof component.local_path !== 'string' || !fs.existsSync(component.local_path)) continue
    const checkout = await checkoutFor(component.local_path)
    if (!checkout || fs.realpathSync(component.local_path) !== checkout.directory) continue
    projects.push({ directory: checkout.directory, component: component.id })
  }
  return projects
}

export function register(roadie) {
  // Managed plugins load before Roadie starts its OpenCode backend. Enable
  // the native API our automatic worktree binding uses; explicit host env wins.
  process.env.OPENCODE_EXPERIMENTAL_WORKSPACES ??= 'true'
  const configPath = process.env.WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG ?? fileURLToPath(new URL('../fork-workspaces.json', import.meta.url))
  roadie.addFilter('fork_workspace', (_provider, request) => (async () => {
    if (_provider) return _provider
    const config = fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath, 'utf8')) : null
    const command = config?.homeboyCommand ?? 'homeboy'
    const source = await checkoutFor(request.sourceDirectory)
    // Once a fork is bound to a repository, its own checkout wins over paths
    // inherited in the parent's history. Otherwise inspect concrete writes;
    // history that is ambiguous across repositories defers to Roadie's
    // ordinary session fork — never an arbitrary repository pick.
    const candidates = source ? [source] : (await Promise.all((request.codingPaths ?? []).map(checkoutFor))).filter(Boolean)
    const commonDirs = new Set(candidates.map((checkout) => checkout.common))
    if (commonDirs.size !== 1) return null
    const checkout = candidates.at(-1)
    const projects = await projectsFor(config, command, request.sourceDirectory)
    const matches = []
    for (const project of projects) if (await commonDirectory(project.directory) === checkout.common) matches.push(project)
    if (!matches.length) throw new Error('The coding repository has no Homeboy owner. Register its repository-root component before forking; no shared-file fork was started.')
    if (matches.length !== 1) throw new Error('Source repository has multiple host workspace bindings; configure exactly one component')
    const project = matches[0]
    return {
      async provision(input) {
        if (!/^[a-f0-9-]{36}$/.test(input.requestId)) return new Error('Invalid fork workspace request identity')
        const base = await run('git', ['rev-parse', 'HEAD'], checkout.directory)
        const branch = `roadie/fork-${input.requestId}`
        const args = ['worktree', 'create', project.component, '--branch', branch, '--from', base, '--run-id', `roadie-fork-${input.requestId}`, '--cleanup-policy', 'preserve-on-failure']
        const response = JSON.parse(await run(command, args, project.directory))
        const record = response.data?.record
        if (response.success !== true || !record || typeof record.worktree_path !== 'string' || !path.isAbsolute(record.worktree_path) || typeof record.id !== 'string' || record.branch !== branch) return new Error('Homeboy did not return a verified fork worktree binding')
        // Git is the ground truth for the checkout Homeboy returned. Never
        // copy dirty source files or silently select a different base ref.
        const actual = await run('git', ['rev-parse', 'HEAD'], record.worktree_path)
        if (actual !== base) return new Error('Homeboy fork workspace does not match the requested committed base')
        return { workingDirectory: record.worktree_path, projectDirectory: project.directory, label: branch, kind: 'git-worktree', workspaceId: record.id, baseRef: base }
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
