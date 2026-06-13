#!/usr/bin/env node
// Isolated Kimaki managed-plugin restart rig for wp-coding-agents.
//
// This script does not start the user's real Kimaki bot and does not touch
// ~/.kimaki. It stages the wp-coding-agents-owned Kimaki config into a temp
// KIMAKI_DATA_DIR, runs the managed post-upgrade hook across simulated restart
// cycles, and proves the OpenCode plugin hooks execute against Kimaki's live
// installed prompt renderer.

import { execFileSync, execSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const args = parseArgs(process.argv.slice(2))
const artifactRoot = path.resolve(args['artifact-dir'] || fs.mkdtempSync(path.join(os.tmpdir(), 'kimaki-managed-plugin-rig-')))
const keep = args.keep === true
const checkLive = args['check-live'] === true || !!args['live-site-dir'] || !!args['live-kimaki-data-dir'] || !!args['live-launchd-plist']

fs.mkdirSync(artifactRoot, { recursive: true })

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kimaki-managed-plugin-rig-work-'))
const kimakiDataDir = path.join(tempRoot, 'kimaki-data')
const kimakiConfigDir = path.join(kimakiDataDir, 'kimaki-config')
const stagedPluginsDir = path.join(kimakiConfigDir, 'plugins')
const stagedSkillsDir = path.join(kimakiConfigDir, 'skills')
const npmSkillsDir = path.join(tempRoot, 'npm-kimaki-skills')
const siteDir = path.join(tempRoot, 'site')
const homeDir = path.join(tempRoot, 'home')

const repoKimakiDir = path.join(repoRoot, 'bridges', 'kimaki')
const repoPluginsDir = path.join(repoKimakiDir, 'plugins')
const postUpgradePath = path.join(kimakiConfigDir, 'post-upgrade.sh')

const artifacts = {
  schema: 'wp-coding-agents/kimaki-managed-plugin-rig/v1',
  repo_root: repoRoot,
  artifact_root: artifactRoot,
  temp_root: keep ? tempRoot : '<removed>',
  kimaki_data_dir: keep ? kimakiDataDir : '<removed>',
  cycles: [],
  checks: [],
  files: {},
}

try {
  stageManagedConfig()
  writeOpencodeConfig()
  recordStaticEvidence()

  await runCycle({ name: 'initial-start', simulatePackageWipe: true })
  await runCycle({ name: 'restart-after-package-wipe', simulatePackageWipe: true })

  if (checkLive) {
    recordLiveDriftEvidence()
  }

  pass('all cycles completed')
  writeJson('manifest.json', artifacts)
  console.log(`PASS kimaki managed-plugin rig`)
  console.log(`Artifacts: ${artifactRoot}`)
} catch (error) {
  artifacts.error = error instanceof Error ? { message: error.message, stack: error.stack } : { message: String(error) }
  writeJson('manifest.json', artifacts)
  console.error(`FAIL kimaki managed-plugin rig: ${artifacts.error.message}`)
  console.error(`Artifacts: ${artifactRoot}`)
  process.exitCode = 1
} finally {
  if (!keep) {
    fs.rmSync(tempRoot, { recursive: true, force: true })
  }
}

function stageManagedConfig() {
  mkdirp(stagedPluginsDir)
  mkdirp(stagedSkillsDir)
  mkdirp(npmSkillsDir)
  mkdirp(siteDir)
  mkdirp(homeDir)

  copyFile(path.join(repoPluginsDir, 'dm-context-filter.ts'), path.join(stagedPluginsDir, 'dm-context-filter.ts'))
  copyFile(path.join(repoPluginsDir, 'dm-agent-sync.ts'), path.join(stagedPluginsDir, 'dm-agent-sync.ts'))
  copyFile(path.join(repoKimakiDir, 'post-upgrade.sh'), postUpgradePath)
  fs.chmodSync(postUpgradePath, 0o755)

  const enableList = path.join(repoKimakiDir, 'skills-enable-list.txt')
  const disableList = path.join(repoKimakiDir, 'skills-disable-list.txt')
  if (fs.existsSync(enableList)) {
    copyFile(enableList, path.join(kimakiConfigDir, 'skills-enable-list.txt'))
  }
  if (fs.existsSync(disableList)) {
    copyFile(disableList, path.join(kimakiConfigDir, 'skills-disable-list.txt'))
  }

  const upgradeSkillDir = path.join(stagedSkillsDir, 'upgrade-wp-coding-agents')
  mkdirp(upgradeSkillDir)
  fs.writeFileSync(path.join(upgradeSkillDir, 'SKILL.md'), '# upgrade-wp-coding-agents test fixture\n', 'utf8')
}

function writeOpencodeConfig() {
  const config = {
    $schema: 'https://opencode.ai/config.json',
    plugin: [
      path.join(stagedPluginsDir, 'dm-context-filter.ts'),
      path.join(stagedPluginsDir, 'dm-agent-sync.ts'),
    ],
    instructions: [],
  }
  writeJson(path.join(siteDir, 'opencode.json'), config)
  writeJson(path.join('site', 'opencode.json'), config)
}

function recordStaticEvidence() {
  artifacts.files['site/opencode.json'] = fileRecord(path.join(siteDir, 'opencode.json'))
  artifacts.files['kimaki-config/plugins/dm-context-filter.ts'] = fileRecord(path.join(stagedPluginsDir, 'dm-context-filter.ts'))
  artifacts.files['kimaki-config/plugins/dm-agent-sync.ts'] = fileRecord(path.join(stagedPluginsDir, 'dm-agent-sync.ts'))
  artifacts.files['kimaki-config/post-upgrade.sh'] = fileRecord(postUpgradePath)
  for (const candidate of ['skills-enable-list.txt', 'skills-disable-list.txt']) {
    const file = path.join(kimakiConfigDir, candidate)
    if (fs.existsSync(file)) {
      artifacts.files[`kimaki-config/${candidate}`] = fileRecord(file)
    }
  }

  const expectedArgs = expectedManagedSkillArgs()
  artifacts.expected_managed_args = [
    'kimaki',
    '--data-dir',
    kimakiDataDir,
    '--auto-restart',
    '--no-critique',
    ...expectedArgs,
  ]
  pass(`expected managed args include ${expectedArgs.join(' ') || '<no skill filters>'}`)
}

function recordLiveDriftEvidence() {
  const live = {
    schema: 'wp-coding-agents/kimaki-live-drift/v1',
    checks: [],
    files: {},
  }
  artifacts.live = live

  const liveSiteDir = path.resolve(args['live-site-dir'] || process.env.DATAMACHINE_SITE_PATH || process.cwd())
  const liveKimakiDataDir = path.resolve(args['live-kimaki-data-dir'] || process.env.KIMAKI_DATA_DIR || path.join(os.homedir(), '.kimaki'))
  const liveConfigDir = path.join(liveKimakiDataDir, 'kimaki-config')
  const livePluginsDir = path.join(liveConfigDir, 'plugins')
  const liveLaunchdPlist = args['live-launchd-plist'] || (process.platform === 'darwin' ? path.join(os.homedir(), 'Library', 'LaunchAgents', 'com.wp.kimaki.plist') : '')

  live.site_dir = liveSiteDir
  live.kimaki_data_dir = liveKimakiDataDir
  live.kimaki_config_dir = liveConfigDir
  live.launchd_plist = liveLaunchdPlist || null

  compareFile({
    label: 'dm-context-filter installed copy matches repo',
    repoFile: path.join(repoPluginsDir, 'dm-context-filter.ts'),
    liveFile: path.join(livePluginsDir, 'dm-context-filter.ts'),
    live,
  })
  compareFile({
    label: 'dm-agent-sync installed copy matches repo',
    repoFile: path.join(repoPluginsDir, 'dm-agent-sync.ts'),
    liveFile: path.join(livePluginsDir, 'dm-agent-sync.ts'),
    live,
  })

  const expectedSkillMode = fs.existsSync(path.join(repoKimakiDir, 'skills-enable-list.txt')) ? 'enable' : 'disable'
  const skillListName = expectedSkillMode === 'enable' ? 'skills-enable-list.txt' : 'skills-disable-list.txt'
  live.expected_skill_mode = expectedSkillMode
  compareFile({
    label: `${skillListName} installed copy matches repo`,
    repoFile: path.join(repoKimakiDir, skillListName),
    liveFile: path.join(liveConfigDir, skillListName),
    live,
  })

  const oppositeSkillList = expectedSkillMode === 'enable' ? 'skills-disable-list.txt' : 'skills-enable-list.txt'
  const oppositeLiveFile = path.join(liveConfigDir, oppositeSkillList)
  liveCheck(!fs.existsSync(oppositeLiveFile), `opposite skill filter ${oppositeSkillList} is absent from live config`, live, {
    file: oppositeLiveFile,
  })

  const opencodeJson = path.join(liveSiteDir, 'opencode.json')
  if (fs.existsSync(opencodeJson)) {
    live.files['site/opencode.json'] = fileRecord(opencodeJson)
    const config = JSON.parse(fs.readFileSync(opencodeJson, 'utf8'))
    const pluginList = Array.isArray(config.plugin) ? config.plugin : []
    live.opencode_plugins = pluginList
    liveCheck(pluginList.includes(path.join(livePluginsDir, 'dm-context-filter.ts')), 'opencode.json references live dm-context-filter path', live)
    liveCheck(pluginList.includes(path.join(livePluginsDir, 'dm-agent-sync.ts')), 'opencode.json references live dm-agent-sync path', live)
  } else {
    liveCheck(false, 'live opencode.json exists', live, { file: opencodeJson })
  }

  if (liveLaunchdPlist && fs.existsSync(liveLaunchdPlist)) {
    live.files['launchd/com.wp.kimaki.plist'] = fileRecord(liveLaunchdPlist)
    const plist = fs.readFileSync(liveLaunchdPlist, 'utf8')
    liveCheck(plist.includes('<string>--no-critique</string>'), 'launchd plist includes --no-critique', live)
    liveCheck(plist.includes('<string>--auto-restart</string>'), 'launchd plist includes --auto-restart', live)
    liveCheck(plist.includes(`<string>${liveKimakiDataDir}</string>`), 'launchd plist points at live KIMAKI_DATA_DIR', live)
    for (const skill of skillNames(path.join(repoKimakiDir, skillListName))) {
      const flag = expectedSkillMode === 'enable' ? '--enable-skill' : '--disable-skill'
      liveCheck(plist.includes(`<string>${flag}</string>`) && plist.includes(`<string>${skill}</string>`), `launchd plist includes ${flag} ${skill}`, live)
    }
  } else if (liveLaunchdPlist) {
    liveCheck(false, 'launchd plist exists', live, { file: liveLaunchdPlist })
  }

  writeJson('live-drift.json', live)
  const driftCount = live.checks.filter((check) => !check.ok).length
  if (driftCount > 0) {
    throw new Error(`live Kimaki managed config drift detected (${driftCount} failed check${driftCount === 1 ? '' : 's'}); see ${path.join(artifactRoot, 'live-drift.json')}`)
  }
}

function compareFile({ label, repoFile, liveFile, live }) {
  const exists = fs.existsSync(liveFile)
  if (exists) {
    live.files[path.relative(live.kimaki_config_dir || path.dirname(liveFile), liveFile)] = fileRecord(liveFile)
  }
  if (!fs.existsSync(repoFile)) {
    liveCheck(false, `${label}: repo source exists`, live, { repoFile })
    return
  }
  if (!exists) {
    liveCheck(false, `${label}: live file exists`, live, { repoFile, liveFile })
    return
  }
  const repoHash = fileRecord(repoFile).sha256
  const liveHash = fileRecord(liveFile).sha256
  liveCheck(repoHash === liveHash, label, live, { repoFile, liveFile, repoHash, liveHash })
}

function liveCheck(ok, label, live, details = {}) {
  const check = { ok, label, ...details }
  live.checks.push(check)
  artifacts.checks.push(check)
}

async function runCycle({ name, simulatePackageWipe }) {
  const cycle = { name, checks: [], files: {} }
  artifacts.cycles.push(cycle)

  if (simulatePackageWipe) {
    fs.rmSync(npmSkillsDir, { recursive: true, force: true })
    mkdirp(npmSkillsDir)
    seedPackageSkill('critique')
    seedPackageSkill('upgrade-wp-coding-agents')
  }

  const postUpgrade = runPostUpgrade(name)
  cycle.post_upgrade = postUpgrade
  assert(postUpgrade.status === 0, `${name}: post-upgrade exits 0`, cycle)
  assert(!fs.existsSync(path.join(npmSkillsDir, 'critique', 'SKILL.md')), `${name}: bundled critique skill removed from npm skills dir`, cycle)
  assert(!fs.existsSync(path.join(npmSkillsDir, 'upgrade-wp-coding-agents', 'SKILL.md')), `${name}: package-local upgrade skill duplicate removed`, cycle)
  assert(fs.existsSync(path.join(stagedSkillsDir, 'upgrade-wp-coding-agents', 'SKILL.md')), `${name}: persistent upgrade skill source remains present`, cycle)
  assert(fs.existsSync(path.join(stagedPluginsDir, 'dm-context-filter.ts')), `${name}: context filter present after restart`, cycle)
  assert(fs.existsSync(path.join(stagedPluginsDir, 'dm-agent-sync.ts')), `${name}: agent sync present after restart`, cycle)

  const permission = expectedSkillPermission()
  assert(permission?.['*'] === 'deny', `${name}: generated skill permission denies unlisted skills`, cycle)
  assert(permission?.['upgrade-wp-coding-agents'] === 'allow', `${name}: generated skill permission allows upgrade skill`, cycle)

  const promptEvidence = await renderAndFilterPrompt(name)
  cycle.prompt = promptEvidence.summary
  cycle.files[`prompts/${name}.raw.txt`] = fileRecord(path.join(artifactRoot, 'prompts', `${name}.raw.txt`))
  cycle.files[`prompts/${name}.filtered.txt`] = fileRecord(path.join(artifactRoot, 'prompts', `${name}.filtered.txt`))

  assert(promptEvidence.rawIncludesTunnel, `${name}: raw Kimaki prompt contains tunnel section`, cycle)
  assert(!promptEvidence.filteredIncludesTunnel, `${name}: filtered prompt removes tunnel section`, cycle)
  assert(promptEvidence.rawStaleOrchestrationLeaks.length > 0, `${name}: raw Kimaki prompt contains stale orchestration sections`, cycle)
  assert(promptEvidence.filteredStaleOrchestrationLeaks.length === 0, `${name}: filtered prompt removes stale orchestration sections`, cycle)
  assert(promptEvidence.contextFilterExecuted, `${name}: dm-context-filter hook executed`, cycle)
  assert(promptEvidence.agentSyncLoaded, `${name}: dm-agent-sync module loads`, cycle)
}

function runPostUpgrade(name) {
  const env = {
    ...process.env,
    HOME: homeDir,
    KIMAKI_DATA_DIR: kimakiDataDir,
    KIMAKI_SKILLS_DIR: npmSkillsDir,
    KIMAKI_SKILL_SOURCE_DIR: stagedSkillsDir,
    KIMAKI_SKILL_ENABLES_FILE: path.join(kimakiConfigDir, 'skills-enable-list.txt'),
    KIMAKI_PLUGIN_SOURCE_DIR: stagedPluginsDir,
    KIMAKI_PLUGINS_DIR: stagedPluginsDir,
  }
  const outPath = path.join(artifactRoot, `post-upgrade.${name}.log`)
  try {
    const stdout = execFileSync(postUpgradePath, { cwd: siteDir, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    fs.writeFileSync(outPath, stdout, 'utf8')
    return { status: 0, log: path.relative(artifactRoot, outPath), stdout }
  } catch (error) {
    const stdout = `${error.stdout || ''}${error.stderr || ''}`
    fs.writeFileSync(outPath, stdout, 'utf8')
    return { status: error.status || 1, log: path.relative(artifactRoot, outPath), stdout }
  }
}

function seedPackageSkill(name) {
  const skillDir = path.join(npmSkillsDir, name)
  mkdirp(skillDir)
  fs.writeFileSync(path.join(skillDir, 'SKILL.md'), `# ${name} package fixture\n`, 'utf8')
}

function expectedSkillPermission() {
  const enableList = path.join(kimakiConfigDir, 'skills-enable-list.txt')
  const disableList = path.join(kimakiConfigDir, 'skills-disable-list.txt')
  if (fs.existsSync(enableList)) {
    return Object.fromEntries([
      ['*', 'deny'],
      ...skillNames(enableList).map((skill) => [skill, 'allow']),
    ])
  }
  if (fs.existsSync(disableList)) {
    return Object.fromEntries(skillNames(disableList).map((skill) => [skill, 'deny']))
  }
  return undefined
}

async function renderAndFilterPrompt(name) {
  const kimakiDistDir = resolveKimakiDistDir()
  const { getOpencodeSystemMessage } = await import(pathToFileURL(path.join(kimakiDistDir, 'system-message.js')).href)
  const { store } = await import(pathToFileURL(path.join(kimakiDistDir, 'store.js')).href)

  const previousCritiqueEnabled = store.getState().critiqueEnabled
  store.setState({ critiqueEnabled: false })
  let raw
  try {
    raw = getOpencodeSystemMessage({
      sessionId: `ses_${name.replace(/[^a-z0-9]/gi, '_')}`,
      channelId: '1493345787894038649',
      guildId: '1493321868415996064',
      threadId: '1514954209622102046',
      channelTopic: 'kimaki managed plugin restart rig',
      agents: [
        { name: 'build', description: 'default coding agent' },
        { name: 'plan', description: 'planning agent' },
      ],
      username: 'chubes',
    })
  } finally {
    store.setState({ critiqueEnabled: previousCritiqueEnabled })
  }

  const contextPluginModule = await import(pathToFileURL(path.join(stagedPluginsDir, 'dm-context-filter.ts')).href)
  const contextPlugin = await contextPluginModule.default({})
  const transform = contextPlugin['experimental.chat.system.transform']
  if (typeof transform !== 'function') {
    throw new Error('dm-context-filter did not expose experimental.chat.system.transform')
  }
  const output = { system: [raw] }
  await transform({}, output)
  const filtered = output.system.join('\n')

  const agentSyncModule = await import(pathToFileURL(path.join(stagedPluginsDir, 'dm-agent-sync.ts')).href)
  const agentSyncPlugin = await agentSyncModule.default({ $: fakeShell })
  const rawStaleOrchestrationLeaks = findStaleOrchestrationLeaks(raw)
  const filteredStaleOrchestrationLeaks = findStaleOrchestrationLeaks(filtered)

  mkdirp(path.join(artifactRoot, 'prompts'))
  fs.writeFileSync(path.join(artifactRoot, 'prompts', `${name}.raw.txt`), normalizeHome(raw), 'utf8')
  fs.writeFileSync(path.join(artifactRoot, 'prompts', `${name}.filtered.txt`), normalizeHome(filtered), 'utf8')

  return {
    rawIncludesTunnel: raw.includes('## running dev servers with tunnel access'),
    filteredIncludesTunnel: filtered.includes('## running dev servers with tunnel access'),
    rawStaleOrchestrationLeaks,
    filteredStaleOrchestrationLeaks,
    contextFilterExecuted: output.system[0] !== raw,
    agentSyncLoaded: !!agentSyncPlugin && typeof agentSyncPlugin === 'object',
    summary: {
      kimaki_dist_dir: kimakiDistDir,
      raw_chars: raw.length,
      filtered_chars: filtered.length,
      stripped_chars: raw.length - filtered.length,
      raw_stale_orchestration_leaks: rawStaleOrchestrationLeaks.length,
      filtered_stale_orchestration_leaks: filteredStaleOrchestrationLeaks.length,
    },
  }
}

function findStaleOrchestrationLeaks(text) {
  const triggers = [
    /^## starting new sessions from CLI$/,
    /^## running opencode commands via kimaki send$/,
    /^## switching agents in the current session$/,
    /^## creating worktrees$/,
    /^## cross-project commands$/,
    /^## waiting for a session to finish$/,
    /\bkimaki send\b/,
    /\bkimaki send\b.*\b--worktree\b/,
    /\bkimaki send\b.*\b--cwd\b/,
    /\bkimaki project (?:list|add|create)\b/,
    /\bkimaki send\b.*\b--project\b/,
    /\bHomeboy\b/,
    /\bData Machine Code\b/,
    /\bdev\.chubes\.net\b/,
  ]
  return text
    .split('\n')
    .map((line, index) => ({ line: index + 1, text: line }))
    .filter(({ text }) => triggers.some((trigger) => trigger.test(text)))
}

function resolveKimakiDistDir() {
  if (args['kimaki-dist-dir']) {
    return path.resolve(args['kimaki-dist-dir'])
  }

  const globalDist = path.join(execSync('npm root -g', { encoding: 'utf8' }).trim(), 'kimaki', 'dist')
  if (fs.existsSync(path.join(globalDist, 'system-message.js'))) {
    artifacts.kimaki_source = { mode: 'global', dist_dir: globalDist }
    return globalDist
  }

  const packageSpec = args['kimaki-package'] || 'kimaki@0.16.0'
  const packageRoot = path.join(tempRoot, 'kimaki-package')
  mkdirp(packageRoot)
  const installLog = path.join(artifactRoot, 'kimaki-package-install.log')
  try {
    const stdout = execFileSync('npm', ['install', '--prefix', packageRoot, packageSpec], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    fs.writeFileSync(installLog, stdout, 'utf8')
  } catch (error) {
    const stdout = `${error.stdout || ''}${error.stderr || ''}`
    fs.writeFileSync(installLog, stdout, 'utf8')
    throw new Error(`failed to install ${packageSpec}; see ${installLog}`)
  }

  const installedDist = path.join(packageRoot, 'node_modules', 'kimaki', 'dist')
  if (!fs.existsSync(path.join(installedDist, 'system-message.js'))) {
    throw new Error(`installed ${packageSpec} but system-message.js was not found at ${installedDist}`)
  }
  artifacts.kimaki_source = { mode: 'temp-npm-install', package: packageSpec, dist_dir: installedDist, install_log: installLog }
  return installedDist
}

function expectedManagedSkillArgs() {
  const enableList = path.join(kimakiConfigDir, 'skills-enable-list.txt')
  const disableList = path.join(kimakiConfigDir, 'skills-disable-list.txt')
  if (fs.existsSync(enableList)) {
    return skillNames(enableList).flatMap((skill) => ['--enable-skill', skill])
  }
  if (fs.existsSync(disableList)) {
    return skillNames(disableList).flatMap((skill) => ['--disable-skill', skill])
  }
  return []
}

function skillNames(file) {
  return fs.readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
}

function fakeShell() {
  return { quiet: () => ({ nothrow: async () => ({ exitCode: 127, stdout: '', stderr: 'fake shell: command disabled in rig' }) }) }
}

function assert(condition, label, cycle) {
  if (!condition) {
    const check = { ok: false, label }
    artifacts.checks.push(check)
    if (cycle) cycle.checks.push(check)
    throw new Error(label)
  }
  const check = { ok: true, label }
  artifacts.checks.push(check)
  if (cycle) cycle.checks.push(check)
}

function pass(label) {
  artifacts.checks.push({ ok: true, label })
}

function fileRecord(file) {
  const buffer = fs.readFileSync(file)
  return { path: file, bytes: buffer.length, sha256: crypto.createHash('sha256').update(buffer).digest('hex') }
}

function copyFile(from, to) {
  mkdirp(path.dirname(to))
  fs.copyFileSync(from, to)
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true })
}

function writeJson(relativeOrAbsolutePath, value) {
  const file = path.isAbsolute(relativeOrAbsolutePath) ? relativeOrAbsolutePath : path.join(artifactRoot, relativeOrAbsolutePath)
  mkdirp(path.dirname(file))
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

function normalizeHome(text) {
  return text
    .split(os.homedir()).join('$HOME')
    .replace(/\/Users\/[^/\s`"']+/g, '$HOME')
    .replace(/\/home\/[^/\s`"']+/g, '$HOME')
    .replace(/\/root(?=\/\.kimaki\b)/g, '$HOME')
}

function parseArgs(argv) {
  const parsed = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    if (key === 'keep') {
      parsed[key] = true
      continue
    }
    parsed[key] = argv[++i]
  }
  return parsed
}
