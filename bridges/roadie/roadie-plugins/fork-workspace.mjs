// Homeboy owns Git worktree allocation, registration and lifecycle. Roadie
// consumes only the resulting directory binding. Projects are explicit host
// configuration so a multi-repository WordPress home is never guessed.
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

export function register(roadie) {
  const configPath = process.env.WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG ?? fileURLToPath(new URL('../fork-workspaces.json', import.meta.url))
  if (!fs.existsSync(configPath)) return
  roadie.addFilter('fork_workspace', async (_provider, request) => {
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
    if (config.version !== 1 || !Array.isArray(config.projects)) throw new Error('Use version 1 and a projects array in fork-workspaces.json')
    const projects = config.projects.filter((project) => typeof project.directory === 'string' && path.isAbsolute(project.directory) && typeof project.component === 'string' && project.component)
    const common = await commonDirectory(request.sourceDirectory).catch(() => null)
    if (!common) return null
    const matches = []
    for (const project of projects) if (await commonDirectory(project.directory) === common) matches.push(project)
    if (!matches.length) return null
    if (matches.length !== 1) throw new Error('Source repository has multiple host workspace bindings; configure exactly one component')
    const project = matches[0]
    return {
      defaultMode: project.defaultMode ?? 'separate',
      async provision(input) {
        if (!/^[a-f0-9-]{36}$/.test(input.requestId)) return new Error('Invalid fork workspace request identity')
        const base = await run('git', ['rev-parse', 'HEAD'], input.sourceDirectory)
        const branch = `roadie/fork-${input.requestId}`
        const args = ['worktree', 'create', project.component, '--branch', branch, '--from', base, '--run-id', `roadie-fork-${input.requestId}`, '--cleanup-policy', 'preserve-on-failure']
        const response = JSON.parse(await run(config.homeboyCommand ?? 'homeboy', args, project.directory))
        const record = response.data?.record
        if (response.success !== true || !record || typeof record.worktree_path !== 'string' || !path.isAbsolute(record.worktree_path) || typeof record.id !== 'string' || record.branch !== branch) return new Error('Homeboy did not return a verified fork worktree binding')
        // Git is the ground truth for the checkout Homeboy returned. Never
        // copy dirty source files or silently select a different base ref.
        const actual = await run('git', ['rev-parse', 'HEAD'], record.worktree_path)
        if (actual !== base) return new Error('Homeboy fork workspace does not match the requested committed base')
        return { workingDirectory: record.worktree_path, projectDirectory: project.directory, label: branch, kind: 'git-worktree', workspaceId: record.id, baseRef: base }
      },
    }
  })
  roadie.addAction('fork_workspace_abandoned', async ({ request, binding }) => {
    if (!binding.workspaceId) return
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
    // Retain evidence and let Homeboy's cleanup policy own later removal.
    await run(config.homeboyCommand ?? 'homeboy', ['worktree', 'finalize', binding.workspaceId, '--owner-run-ref', `roadie-fork-${request.requestId}`, '--disposition', 'failed'], binding.projectDirectory)
  })
}
