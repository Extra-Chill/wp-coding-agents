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
if (args['self-test-args'] === true) {
  runArgSelfTest()
  process.exit(0)
}
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
    await recordLiveDriftEvidence()
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

async function recordLiveDriftEvidence() {
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

  const expectedSkillMode = fs.existsSync(path.join(repoKimakiDir, 'skills-enable-list.txt')) ? 'enable' : 'disable'
  const skillListName = expectedSkillMode === 'enable' ? 'skills-enable-list.txt' : 'skills-disable-list.txt'
  const liveFreshnessFiles = [
    path.join(livePluginsDir, 'dm-context-filter.ts'),
    path.join(livePluginsDir, 'dm-agent-sync.ts'),
    path.join(liveConfigDir, 'post-upgrade.sh'),
    path.join(liveConfigDir, skillListName),
    liveLaunchdPlist,
  ].filter(Boolean)
  live.expected_skill_mode = expectedSkillMode
  live.expected_skills = skillNames(path.join(repoKimakiDir, skillListName))
  live.expected_managed_args = managedArgsFor(liveKimakiDataDir, path.join(repoKimakiDir, skillListName), expectedSkillMode)

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

  await recordLiveRuntimeEvidence({
    live,
    liveSiteDir,
    liveKimakiDataDir,
    liveConfigDir,
    livePluginsDir,
    liveLaunchdPlist,
    liveFreshnessFiles,
    expectedSkillMode,
    skillListName,
  })

  writeJson('live-drift.json', live)
  const driftCount = live.checks.filter((check) => !check.ok).length
  if (driftCount > 0) {
    throw new Error(`live Kimaki managed config drift detected (${driftCount} failed check${driftCount === 1 ? '' : 's'}); see ${path.join(artifactRoot, 'live-drift.json')}`)
  }
}

async function recordLiveRuntimeEvidence({ live, liveSiteDir, liveKimakiDataDir, liveConfigDir, livePluginsDir, liveLaunchdPlist, liveFreshnessFiles, expectedSkillMode, skillListName }) {
  const processes = listProcesses()
  live.processes = {
    kimaki: processes.filter(isKimakiProcess).map(enrichProcess),
    opencode_serve: processes.filter(isOpencodeServeProcess).map(enrichProcess),
  }

  const expectedSkillFile = path.join(repoKimakiDir, skillListName)
  const expectedManagedArgs = managedArgsFor(liveKimakiDataDir, expectedSkillFile, expectedSkillMode)
  const managedKimakiProcesses = live.processes.kimaki.filter((processInfo) => processHasManagedArgs(processInfo.command, expectedManagedArgs))
  live.managed_kimaki_processes = managedKimakiProcesses

  liveCheck(live.processes.kimaki.length > 0, 'active Kimaki process found', live, { class: 'stale/manual Kimaki process' })
  liveCheck(managedKimakiProcesses.length > 0, 'active Kimaki process uses managed launch args', live, {
    class: 'stale/manual Kimaki process',
    expectedArgs: expectedManagedArgs,
  })

  const unexpectedSkillArgs = live.processes.kimaki.flatMap((processInfo) => unexpectedKimakiSkillArgs(processInfo.command, expectedSkillMode, live.expected_skills))
  live.unexpected_skill_args = unexpectedSkillArgs
  liveCheck(unexpectedSkillArgs.length === 0, 'active Kimaki process exposes only allowlisted skill args', live, {
    class: 'skill allowlist not applied',
    unexpectedSkillArgs,
  })

  const launchdEvidence = liveLaunchdPlist ? inspectLaunchdService('com.wp.kimaki') : null
  if (launchdEvidence) {
    live.launchd_service = launchdEvidence
    if (launchdEvidence.ok && launchdEvidence.pid) {
      liveCheck(managedKimakiProcesses.some((processInfo) => processInfo.pid === launchdEvidence.pid), 'active Kimaki process PID matches launchd service', live, {
        class: 'stale/manual Kimaki process',
        launchdPid: launchdEvidence.pid,
      })
    } else {
      liveCheck(false, 'launchd service exposes active Kimaki PID', live, {
        class: 'stale/manual Kimaki process',
        launchd: launchdEvidence,
      })
    }
  }

  liveCheck(live.processes.opencode_serve.length > 0, 'active OpenCode serve process found', live, { class: 'stale OpenCode server' })
  const opencodeFromManagedKimaki = live.processes.opencode_serve.filter((processInfo) => hasAncestor(processInfo, managedKimakiProcesses, processes))
  liveCheck(opencodeFromManagedKimaki.length > 0, 'active OpenCode serve process descends from managed Kimaki process', live, {
    class: 'stale OpenCode server',
    liveSiteDir,
  })

  const freshness = managedRuntimeFreshness(opencodeFromManagedKimaki, liveFreshnessFiles)
  live.runtime_freshness = freshness
  liveCheck(freshness.fresh, 'active OpenCode serve process started after managed Kimaki config files', live, {
    class: 'stale OpenCode server',
    newestManagedConfig: freshness.newestManagedConfig,
    staleProcesses: freshness.staleProcesses,
  })

  const staleOpenCodeServers = live.processes.opencode_serve.filter((processInfo) => !hasAncestor(processInfo, managedKimakiProcesses, processes))
  live.stale_opencode_serve = staleOpenCodeServers
  liveCheck(staleOpenCodeServers.length === 0, 'no stale OpenCode serve processes outside managed Kimaki ancestry', live, {
    class: 'stale OpenCode server',
    stale: staleOpenCodeServers,
  })

  const livePromptEvidence = await renderLivePromptEvidence({ liveConfigDir, livePluginsDir })
  live.prompt = livePromptEvidence.summary
  if (livePromptEvidence.rawPath) {
    live.files['prompts/live.raw.txt'] = fileRecord(livePromptEvidence.rawPath)
  }
  if (livePromptEvidence.filteredPath) {
    live.files['prompts/live.filtered.txt'] = fileRecord(livePromptEvidence.filteredPath)
  }
  liveCheck(livePromptEvidence.contextFilterExecuted, 'live dm-context-filter transform executes', live, { class: 'plugin not loaded' })
  liveCheck(livePromptEvidence.managedPromptActive, 'live effective prompt uses managed bridge prompt', live, { class: 'plugin match predicate failed' })
  liveCheck(livePromptEvidence.joinedSystemPrefixPreserved, 'live final system transform preserves non-Kimaki prefix', live, { class: 'plugin overmatched final system block' })
  liveCheck(livePromptEvidence.joinedSystemStaleOrchestrationLeaks.length === 0, 'live final system transform strips Kimaki promptAsync system field', live, {
    class: 'plugin match predicate failed',
    leaks: livePromptEvidence.joinedSystemStaleOrchestrationLeaks,
  })
  liveCheck(livePromptEvidence.filteredStaleOrchestrationLeaks.length === 0, 'live effective prompt has no non-allowlisted Kimaki prompt surface', live, {
    class: 'plugin match predicate failed',
    leaks: livePromptEvidence.filteredStaleOrchestrationLeaks,
  })
}

async function renderLivePromptEvidence({ liveConfigDir, livePluginsDir }) {
  const kimakiDistDir = resolveKimakiDistDir()
  const rawPath = path.join(artifactRoot, 'prompts', 'live.raw.txt')
  const filteredPath = path.join(artifactRoot, 'prompts', 'live.filtered.txt')
  const summary = {
    kimaki_dist_dir: kimakiDistDir,
    live_config_dir: liveConfigDir,
    live_plugins_dir: livePluginsDir,
  }

  try {
    return await renderPromptWithPlugin({
      name: 'live',
      kimakiDistDir,
      pluginsDir: livePluginsDir,
      rawPath,
      filteredPath,
      summary,
    })
  } catch (error) {
    return {
      rawPath: fs.existsSync(rawPath) ? rawPath : null,
      filteredPath: fs.existsSync(filteredPath) ? filteredPath : null,
      rawStaleOrchestrationLeaks: [],
      filteredStaleOrchestrationLeaks: [{ line: 0, text: error instanceof Error ? error.message : String(error) }],
      joinedSystemStaleOrchestrationLeaks: [{ line: 0, text: error instanceof Error ? error.message : String(error) }],
      contextFilterExecuted: false,
      managedPromptActive: false,
      joinedSystemPrefixPreserved: false,
      summary: { ...summary, error: error instanceof Error ? error.message : String(error) },
    }
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

  assert(promptEvidence.rawIncludesTunnel || promptEvidence.rawManagedPromptActive, `${name}: raw Kimaki prompt is generic or already managed`, cycle)
  assert(!promptEvidence.filteredIncludesTunnel, `${name}: filtered prompt removes tunnel section`, cycle)
  assert(promptEvidence.rawStaleOrchestrationLeaks.length > 0 || promptEvidence.rawManagedPromptActive, `${name}: raw Kimaki prompt contains stale orchestration sections or is already managed`, cycle)
  assert(promptEvidence.filteredStaleOrchestrationLeaks.length === 0, `${name}: filtered prompt removes stale orchestration sections`, cycle)
  assert(promptEvidence.contextFilterExecuted, `${name}: dm-context-filter hook executed`, cycle)
  assert(promptEvidence.joinedSystemPrefixPreserved, `${name}: final system transform preserves non-Kimaki prefix`, cycle)
  assert(promptEvidence.joinedSystemInstructionSuffixPreserved, `${name}: final system transform preserves trailing instruction blocks`, cycle)
  assert(promptEvidence.joinedSystemStaleOrchestrationLeaks.length === 0, `${name}: final system transform strips Kimaki promptAsync system field`, cycle)
  assert(promptEvidence.systemAndMessageTransformsAgree, `${name}: system and message transforms agree`, cycle)
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
  fs.writeFileSync(path.join(skillDir, 'SKILL.md'), `# ${name} stale package fixture\n`, 'utf8')
}

async function renderAndFilterPrompt(name) {
  const kimakiDistDir = resolveKimakiDistDir()
  return renderPromptWithPlugin({
    name,
    kimakiDistDir,
    pluginsDir: stagedPluginsDir,
    rawPath: path.join(artifactRoot, 'prompts', `${name}.raw.txt`),
    filteredPath: path.join(artifactRoot, 'prompts', `${name}.filtered.txt`),
    summary: {},
  })
}

async function renderPromptWithPlugin({ name, kimakiDistDir, pluginsDir, rawPath, filteredPath, summary }) {
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

  const contextPluginModule = await import(pathToFileURL(path.join(pluginsDir, 'dm-context-filter.ts')).href)
  const contextPlugin = await contextPluginModule.default({})
  const systemTransform = contextPlugin['experimental.chat.system.transform']
  if (typeof systemTransform !== 'function') {
    throw new Error('dm-context-filter did not expose experimental.chat.system.transform')
  }
  const systemOutput = { system: [raw] }
  await systemTransform({}, systemOutput)
  const systemFiltered = systemOutput.system.join('\n')
  const joinedSystemPrefix = '## Sentinel Joined System Prefix\n\nThis block represents composed Data Machine AGENTS guidance.'
  const joinedSystemOutput = { system: [`${joinedSystemPrefix}\n\n${raw}`] }
  await systemTransform({}, joinedSystemOutput)
  const joinedSystemFiltered = joinedSystemOutput.system.join('\n')
  const soulInstruction = 'Instructions from: /tmp/SOUL.md\n# Agent Soul\n\n## Interests\n\nMaster chef, cooking delicious software with holistic practices.'
  const joinedSystemWithSuffixOutput = { system: [`${raw}\n\n${soulInstruction}`] }
  await systemTransform({}, joinedSystemWithSuffixOutput)
  const joinedSystemWithSuffixFiltered = joinedSystemWithSuffixOutput.system.join('\n')

  const messageTransform = contextPlugin['experimental.chat.messages.transform']
  if (typeof messageTransform !== 'function') {
    throw new Error('dm-context-filter did not expose experimental.chat.messages.transform')
  }
  const messageOutput = {
    messages: [
      {
        info: { id: `msg_${name}` },
        parts: [{ type: 'text', text: raw }],
      },
    ],
  }
  await messageTransform({}, messageOutput)
  const filtered = messageOutput.messages[0].parts[0].text

  const agentSyncModule = await import(pathToFileURL(path.join(pluginsDir, 'dm-agent-sync.ts')).href)
  const agentSyncPlugin = await agentSyncModule.default({ $: fakeShell })
  const rawStaleOrchestrationLeaks = findStaleOrchestrationLeaks(raw)
  const filteredStaleOrchestrationLeaks = findStaleOrchestrationLeaks(filtered)
  const joinedSystemStaleOrchestrationLeaks = findStaleOrchestrationLeaks(joinedSystemFiltered)

  mkdirp(path.join(artifactRoot, 'prompts'))
  fs.writeFileSync(rawPath, normalizeHome(raw), 'utf8')
  fs.writeFileSync(filteredPath, normalizeHome(filtered), 'utf8')

  return {
    rawPath,
    filteredPath,
    rawIncludesTunnel: raw.includes('## running dev servers with tunnel access'),
    rawManagedPromptActive: raw.includes('## Kimaki Discord Bridge') && raw.includes('## Managed Coding Runtime'),
    filteredIncludesTunnel: filtered.includes('## running dev servers with tunnel access'),
    rawStaleOrchestrationLeaks,
    filteredStaleOrchestrationLeaks,
    joinedSystemStaleOrchestrationLeaks,
    contextFilterExecuted: systemOutput.system[0] !== raw && filtered !== raw,
    managedPromptActive: filtered.includes('## Kimaki Discord Bridge') && filtered.includes('## Managed Coding Runtime'),
    joinedSystemPrefixPreserved: joinedSystemFiltered.includes(joinedSystemPrefix) && joinedSystemFiltered.includes('## Kimaki Discord Bridge'),
    joinedSystemInstructionSuffixPreserved: joinedSystemWithSuffixFiltered.includes(soulInstruction),
    systemAndMessageTransformsAgree: systemFiltered === filtered,
    agentSyncLoaded: !!agentSyncPlugin && typeof agentSyncPlugin === 'object',
    summary: {
      ...summary,
      kimaki_dist_dir: kimakiDistDir,
      raw_chars: raw.length,
      filtered_chars: filtered.length,
      stripped_chars: raw.length - filtered.length,
      raw_stale_orchestration_leaks: rawStaleOrchestrationLeaks.length,
      filtered_stale_orchestration_leaks: filteredStaleOrchestrationLeaks.length,
      joined_system_stale_orchestration_leaks: joinedSystemStaleOrchestrationLeaks.length,
      joined_system_instruction_suffix_preserved: joinedSystemWithSuffixFiltered.includes(soulInstruction),
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

function managedArgsFor(dataDir, skillFile, mode = fs.existsSync(path.join(repoKimakiDir, 'skills-enable-list.txt')) ? 'enable' : 'disable') {
  const skillFlag = mode === 'enable' ? '--enable-skill' : '--disable-skill'
  return [
    '--data-dir',
    dataDir,
    '--auto-restart',
    '--no-critique',
    ...skillNames(skillFile).flatMap((skill) => [skillFlag, skill]),
  ]
}

function processHasManagedArgs(command, expectedArgs) {
  return expectedArgs.every((expectedArg) => commandIncludesArg(command, expectedArg))
}

function commandIncludesArg(command, expectedArg) {
  return command === expectedArg || command.includes(` ${expectedArg} `) || command.endsWith(` ${expectedArg}`) || command.includes(`=${expectedArg}`)
}

function unexpectedKimakiSkillArgs(command, expectedMode, expectedSkills) {
  const expected = new Set(expectedSkills)
  const unexpected = []
  const tokens = shellishTokens(command)
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index]
    if (token !== '--enable-skill' && token !== '--disable-skill') {
      continue
    }
    const skill = tokens[index + 1] || ''
    const expectedFlag = expectedMode === 'enable' ? '--enable-skill' : '--disable-skill'
    if (token !== expectedFlag || !expected.has(skill)) {
      unexpected.push({ flag: token, skill })
    }
  }
  return unexpected
}

function shellishTokens(command) {
  const matches = command.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || []
  return matches.map((token) => token.replace(/^['"]|['"]$/g, ''))
}

function listProcesses() {
  try {
    const stdout = execFileSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' })
    return stdout
      .split('\n')
      .map((line) => line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/))
      .filter(Boolean)
      .map((match) => ({ pid: Number(match[1]), ppid: Number(match[2]), command: match[3] }))
  } catch (error) {
    return []
  }
}

function isKimakiProcess(processInfo) {
  const command = processInfo.command
  return /(^|[/\s])kimaki(\s|$)/.test(command) && !command.includes('kimaki-managed-plugin-rig.mjs')
}

function isOpencodeServeProcess(processInfo) {
  const command = processInfo.command
  return command.includes('opencode') && /\bserve\b/.test(command)
}

function enrichProcess(processInfo) {
  return { ...processInfo, cwd: processCwd(processInfo.pid), started_at: processStartedAt(processInfo.pid) }
}

function managedRuntimeFreshness(opencodeProcesses, freshnessFiles) {
  const newestManagedConfig = newestFileMtime(freshnessFiles)
  const staleProcesses = opencodeProcesses
    .filter((processInfo) => !processInfo.started_at || (newestManagedConfig?.mtimeMs && Date.parse(processInfo.started_at) < newestManagedConfig.mtimeMs))
    .map((processInfo) => ({
      pid: processInfo.pid,
      started_at: processInfo.started_at,
      command: processInfo.command,
      cwd: processInfo.cwd,
    }))

  return {
    fresh: !!newestManagedConfig && opencodeProcesses.length > 0 && staleProcesses.length === 0,
    newestManagedConfig,
    staleProcesses,
  }
}

function newestFileMtime(files) {
  let newest = null
  for (const file of files) {
    if (!file || !fs.existsSync(file)) {
      continue
    }
    const stats = fs.statSync(file)
    const record = { file, mtimeMs: stats.mtimeMs, mtime: stats.mtime.toISOString() }
    if (!newest || record.mtimeMs > newest.mtimeMs) {
      newest = record
    }
  }
  return newest
}

function hasAncestor(processInfo, ancestorCandidates, processes) {
  const ancestors = new Set(ancestorCandidates.map((candidate) => candidate.pid))
  const processByPid = new Map(processes.map((candidate) => [candidate.pid, candidate]))
  let current = processInfo
  while (current && current.ppid > 0) {
    if (ancestors.has(current.ppid)) {
      return true
    }
    current = processByPid.get(current.ppid)
  }
  return false
}

function processCwd(pid) {
  if (process.platform === 'linux') {
    try {
      return fs.realpathSync(`/proc/${pid}/cwd`)
    } catch {
      return null
    }
  }
  try {
    const stdout = execFileSync('lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    const line = stdout.split('\n').find((candidate) => candidate.startsWith('n'))
    return line ? line.slice(1) : null
  } catch {
    return null
  }
}

function processStartedAt(pid) {
  if (process.platform === 'linux') {
    return linuxProcessStartedAt(pid)
  }

  try {
    const stdout = execFileSync('ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    const parsed = Date.parse(stdout)
    return Number.isNaN(parsed) ? null : new Date(parsed).toISOString()
  } catch {
    return null
  }
}

function linuxProcessStartedAt(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8')
    const parts = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)
    const startTicks = Number(parts[19])
    const clockTicks = Number(execFileSync('getconf', ['CLK_TCK'], { encoding: 'utf8' }).trim()) || 100
    const bootTime = linuxBootTimeMs()
    if (!bootTime || !Number.isFinite(startTicks)) {
      return null
    }
    return new Date(bootTime + (startTicks / clockTicks) * 1000).toISOString()
  } catch {
    return null
  }
}

function linuxBootTimeMs() {
  try {
    const stat = fs.readFileSync('/proc/stat', 'utf8')
    const match = stat.match(/^btime\s+(\d+)$/m)
    return match ? Number(match[1]) * 1000 : null
  } catch {
    return null
  }
}

function inspectLaunchdService(label) {
  if (process.platform !== 'darwin') {
    return null
  }
  try {
    const stdout = execFileSync('launchctl', ['print', `gui/${process.getuid()}/${label}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    const pidMatch = stdout.match(/\bpid = (\d+)\b/)
    return { ok: true, label, pid: pidMatch ? Number(pidMatch[1]) : null, stdout: truncate(redactSensitiveText(stdout)) }
  } catch (error) {
    return { ok: false, label, status: error.status || 1, stdout: truncate(redactSensitiveText(`${error.stdout || ''}${error.stderr || ''}`)) }
  }
}

function redactSensitiveText(text) {
  if (typeof text !== 'string') {
    return text
  }
  return text
    .replace(/(\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY)[A-Z0-9_]*\s*=>\s*)[^\n]+/g, '$1<redacted>')
    .replace(/(\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY)[A-Z0-9_]*\s*=\s*)(?!>)[^\s\n]+/g, '$1<redacted>')
}

function truncate(text, max = 8000) {
  if (typeof text !== 'string' || text.length <= max) {
    return text
  }
  return `${text.slice(0, max)}\n<truncated ${text.length - max} bytes>`
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
  const booleanFlags = new Set(['keep', 'check-live', 'self-test-args'])
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const [key, inlineValue] = arg.slice(2).split(/=(.*)/s, 2)
    if (inlineValue !== undefined) {
      parsed[key] = inlineValue
      continue
    }
    if (booleanFlags.has(key)) {
      parsed[key] = true
      continue
    }
    parsed[key] = argv[++i]
  }
  return parsed
}

function runArgSelfTest() {
  const parsed = parseArgs(['--check-live', '--live-site-dir', '/tmp/site', '--keep', '--artifact-dir=/tmp/artifacts'])
  const failures = []
  if (parsed['check-live'] !== true) failures.push('--check-live should parse as boolean true')
  if (parsed['live-site-dir'] !== '/tmp/site') failures.push('--live-site-dir should consume /tmp/site')
  if (parsed.keep !== true) failures.push('--keep should parse as boolean true')
  if (parsed['artifact-dir'] !== '/tmp/artifacts') failures.push('--artifact-dir=value should parse inline value')
  const processFixtures = [
    { pid: 10, ppid: 1, command: 'node /bin/kimaki --data-dir /tmp/kimaki --auto-restart --no-critique' },
    { pid: 11, ppid: 10, command: 'node /bin/opencode serve --port 12345' },
    { pid: 12, ppid: 1, command: 'node /bin/opencode serve --port 23456' },
  ]
  const managedKimakiFixtures = [processFixtures[0]]
  const staleOpenCodeFixtures = processFixtures
    .filter(isOpencodeServeProcess)
    .filter((processInfo) => !hasAncestor(processInfo, managedKimakiFixtures, processFixtures))
  if (staleOpenCodeFixtures.length !== 1 || staleOpenCodeFixtures[0].pid !== 12) {
    failures.push('stale OpenCode process detector should flag orphaned serve process')
  }
  if (failures.length > 0) {
    throw new Error(`argument parser self-test failed: ${failures.join('; ')}`)
  }
  console.log('PASS kimaki managed-plugin rig arg parser self-test')
}
