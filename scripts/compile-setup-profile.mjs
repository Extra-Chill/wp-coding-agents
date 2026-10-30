#!/usr/bin/env node

import fs from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"
import process from "node:process"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

function usage() {
  return `Usage: node scripts/compile-setup-profile.mjs [profile.json]

Reads a normalized wp-coding-agents setup profile from a JSON file or stdin and
prints a deterministic setup plan as JSON.
`
}

function readJson() {
  const arg = process.argv[2]
  if (arg === "--help" || arg === "-h") {
    process.stdout.write(usage())
    process.exit(0)
  }

  const input = arg ? fs.readFileSync(arg, "utf8") : fs.readFileSync(0, "utf8")
  try {
    return JSON.parse(input)
  } catch (error) {
    throw new Error(`Invalid setup profile JSON: ${error.message}`)
  }
}

function discoveredNames(dir, suffix = ".sh", skip = new Set()) {
  const full = path.join(repoRoot, dir)
  return fs
    .readdirSync(full)
    .filter((file) => file.endsWith(suffix))
    .map((file) => path.basename(file, suffix))
    .filter((name) => !skip.has(name))
    .sort()
}

function shellQuote(value) {
  const string = String(value)
  if (string === "~") {
    return "$HOME"
  }
  if (string.startsWith("~/")) {
    const rest = string.slice(2).replace(/["\\$`]/g, "\\$&")
    return `"$HOME/${rest}"`
  }
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(string)) {
    return string
  }
  return `'${string.replaceAll("'", "'\\''")}'`
}

function addFlag(command, flag, value) {
  command.push(flag)
  if (value !== undefined) {
    command.push(value)
  }
}

function formatCommand(env, args, dryRun = false) {
  const renderedEnv = Object.entries(env).map(([key, value]) => `${key}=${shellQuote(value)}`)
  const renderedArgs = [...args, ...(dryRun ? ["--dry-run"] : [])].map(shellQuote)
  return [...renderedEnv, ...renderedArgs].join(" ")
}

function ensureKnown(value, known, label) {
  if (value && value !== "auto" && !known.includes(value)) {
    throw new Error(`Unknown ${label}: ${value}. Available: ${known.join(", ")}`)
  }
}

// Codex and Claude Code are no longer managed runtimes (#751). Both read the
// composed AGENTS.md natively when run in a terminal.
const REMOVED_RUNTIMES = ["codex", "claude-code"]

function normalizeRuntime(profile, availableRuntimes) {
  const runtime = profile.runtime ?? {}
  const selection = runtime.selection || "auto"
  if (REMOVED_RUNTIMES.includes(selection)) {
    throw new Error(
      `runtime.selection '${selection}' was removed (wp-coding-agents#751). Use Pi with Roadie, or run ${selection} yourself in a terminal against the site's composed AGENTS.md.`
    )
  }

  ensureKnown(selection, availableRuntimes, "runtime")
  return { selection, requested: selection === "auto" ? [] : [selection], flag: selection === "auto" ? null : selection }
}

// Kimaki was replaced by Roadie; saved profiles that name it select Roadie,
// matching upgrade.sh's bridge mapping.
const BRIDGE_ALIASES = { kimaki: "roadie" }

function normalizeBridge(profile, availableBridges) {
  const requested = profile.chat_bridge?.selection || "auto"
  const selection = BRIDGE_ALIASES[requested] ?? requested
  if (selection !== "none") {
    ensureKnown(selection, availableBridges, "chat bridge")
  }
  return selection
}

function normalizeSource(profile) {
  const source = profile.source
  if (source === undefined) {
    return { mode: "workspace", repositories: [], entries: [], legacy: true }
  }
  if (!source || typeof source !== "object") {
    throw new Error("source must be an object")
  }

  const mode = source.mode
  if (!["workspace", "owned"].includes(mode)) {
    throw new Error("source.mode must be workspace or owned")
  }

  const declarations = source.workspace_repositories
  if (!Array.isArray(declarations)) {
    throw new Error("source.workspace_repositories must be an array")
  }
  const entries = declarations.map((repository) => {
    if (typeof repository === "string") return { path: repository }
    if (!repository || typeof repository !== "object" || Array.isArray(repository)) {
      throw new Error("source.workspace_repositories entries must be absolute paths or {path, remote} objects")
    }
    return { path: repository.path, remote: repository.remote }
  })
  if (entries.some((repository) => typeof repository.path !== "string" || !repository.path || !path.isAbsolute(repository.path))) {
    throw new Error("source.workspace_repositories paths must be absolute")
  }
  if (entries.some((repository) => repository.remote !== undefined && (typeof repository.remote !== "string" || !repository.remote))) {
    throw new Error("source.workspace_repositories remote must be a non-empty string")
  }
  if (entries.some((repository) => repository.remote && (/^-|[\t\n]/.test(repository.remote) || /[:\t\n]/.test(repository.path)))) {
    throw new Error("materialized workspace repository remotes and destinations contain invalid characters")
  }
  if (entries.some((repository) => /^https:\/\/[^/]*@/.test(repository.remote || "") || /^ssh:\/\/[^/@]*:[^/@]*@/.test(repository.remote || ""))) {
    throw new Error("source.workspace_repositories remotes must not contain embedded credentials")
  }
  if (entries.some((repository) => repository.remote && !(/^(\/|file:\/\/\/|https:\/\/|ssh:\/\/|git@[^:]+:)/.test(repository.remote)))) {
    throw new Error("source.workspace_repositories remotes must use an absolute local path, file, HTTPS, or SSH URL")
  }
  const repositories = entries.map((repository) => repository.path)
  if (new Set(repositories).size !== repositories.length) {
    throw new Error("source.workspace_repositories must not contain duplicate paths")
  }
  if (mode === "workspace" && !repositories.length) {
    throw new Error("workspace source mode requires one or more source.workspace_repositories")
  }
  if (mode === "owned" && repositories.length) {
    throw new Error("owned source mode must not declare source.workspace_repositories")
  }

  return { mode, repositories, entries, legacy: false }
}

function compile(profile) {
  const availableRuntimes = discoveredNames("runtimes")
  const availableBridges = discoveredNames("bridges", ".sh", new Set(["_dispatch"]))
  const warnings = []
  const env = {}
  const command = ["./setup.sh"]

  const installTarget = profile.install_target
  const target = profile.target ?? {}
  const overlays = profile.overlays ?? {}
  const systemsCapabilities = profile.systems_capabilities ?? {}
  const agent = profile.agent ?? {}
  const source = normalizeSource(profile)
  if (source.legacy) {
    warnings.push("Legacy profile has no source declaration: no new mutable repository authority is declared until source.workspace_repositories is added.")
  }

  if (!installTarget) {
    throw new Error("Missing required profile field: install_target")
  }

  switch (installTarget) {
    case "local":
      if (!target.wordpress_path) throw new Error("Local setup requires target.wordpress_path")
      env.EXISTING_WP = target.wordpress_path
      addFlag(command, "--local")
      break
    case "fresh-vps":
      if (!target.domain) throw new Error("Fresh VPS setup requires target.domain")
      env.SITE_DOMAIN = target.domain
      break
    case "existing-vps":
      if (!target.wordpress_path) throw new Error("Existing VPS setup requires target.wordpress_path")
      env.EXISTING_WP = target.wordpress_path
      addFlag(command, "--existing")
      break
    case "migration":
      if (!target.wordpress_path) throw new Error("Migration setup requires target.wordpress_path")
      if (!target.migration_backups_ready) warnings.push("Import database and wp-content before running the compiled setup command.")
      env.EXISTING_WP = target.wordpress_path
      addFlag(command, "--existing")
      break
    case "external-runtime":
      if (!target.runtime_project_root) throw new Error("External runtime setup requires target.runtime_project_root")
      if (!target.wordpress_path) throw new Error("External runtime setup requires target.wordpress_path")
      if (!target.control_transport_argv) throw new Error("External runtime setup requires target.control_transport_argv")
      if (!Array.isArray(target.control_transport_argv) || !target.control_transport_argv.length || target.control_transport_argv.some((value) => typeof value !== "string" || !value)) {
        throw new Error("target.control_transport_argv must be a non-empty argv array")
      }
      env.RUNTIME_PROJECT_ROOT = target.runtime_project_root
      env.WP_CONTROL_TRANSPORT_JSON = JSON.stringify(target.control_transport_argv)
      addFlag(command, "--external-wordpress")
      addFlag(command, "--wordpress-path", target.wordpress_path)
      if (target.wordpress_user) addFlag(command, "--wordpress-user", target.wordpress_user)
      break
    default:
      throw new Error(`Unknown install_target: ${installTarget}`)
  }

  if (target.wordpress_studio || overlays.wordpress_studio) {
    env.WP_CLI_TRANSPORT_JSON = '["studio","wp"]'
  }

  const runtime = normalizeRuntime(profile, availableRuntimes)
  if (profile.codex_path !== undefined) {
    throw new Error("codex_path was renamed provider_path when the Codex runtime was removed (wp-coding-agents#751)")
  }
  if (installTarget === "external-runtime" && runtime.selection !== "opencode") {
    throw new Error("External runtime setup currently requires runtime.selection=opencode")
  }
  if (runtime.flag) {
    addFlag(command, "--runtime", runtime.flag)
  }

  if (!source.legacy) {
    addFlag(command, "--source-mode", source.mode)
    for (const repository of source.entries) {
      if (repository.remote) {
        addFlag(command, "--workspace-repository-clone", repository.remote)
        command.push(repository.path)
      } else {
        addFlag(command, "--workspace-repository", repository.path)
      }
    }
  }

  const bridge = normalizeBridge(profile, availableBridges)
  if (bridge === "none") {
    addFlag(command, "--no-chat")
  } else if (bridge !== "auto") {
    addFlag(command, "--chat", bridge)
  }
  const effectiveBridge = bridge

  if (overlays.homeboy) addFlag(command, "--with-homeboy")
  if (profile.provider_path === "external-openai-compatible-endpoint") addFlag(command, "--with-ai-gateway")
  if (overlays.multisite || overlays.subdomain_multisite) addFlag(command, "--multisite")
  if (overlays.subdomain_multisite) addFlag(command, "--subdomain")
  if (overlays.skip_deps) addFlag(command, "--skip-deps")
  if (overlays.skip_ssl) addFlag(command, "--skip-ssl")
  if (overlays.skip_skills) addFlag(command, "--no-skills")
  if (overlays.root === true) addFlag(command, "--root")
  if (overlays.root === false) addFlag(command, "--non-root")
  if (agent.slug) addFlag(command, "--agent-slug", agent.slug)
  if (agent.name) addFlag(command, "--agent-name", agent.name)
  if (systemsCapabilities.profile && systemsCapabilities.profile !== "none") {
    if (systemsCapabilities.profile !== "managed-vps") throw new Error(`Unknown systems capability profile: ${systemsCapabilities.profile}`)
    if (!["fresh-vps", "existing-vps", "migration"].includes(installTarget)) {
      throw new Error("The managed-vps systems capability profile requires a colocated VPS install")
    }
    addFlag(command, "--systems-capabilities", systemsCapabilities.profile)
  }

  const verification = new Set(installTarget === "external-runtime" ? ["verify-external-wordpress-transport", "verify-data-machine-projection"] : ["verify-wordpress", "verify-data-machine"])
  if (target.wordpress_studio || overlays.wordpress_studio) verification.add("verify-wordpress-studio")
  if (installTarget === "fresh-vps" || installTarget === "existing-vps") verification.add("verify-vps-reachable")

  const runtimeNames = runtime.requested
  for (const name of runtimeNames) {
    verification.add(`verify-runtime-${name}`)
  }

  if (effectiveBridge === "none") {
    verification.add("verify-bridge-none")
  } else if (effectiveBridge !== "auto") {
    verification.add(`verify-bridge-${effectiveBridge}`)
    if (effectiveBridge === "roadie" && (runtimeNames.includes("opencode") || runtime.selection === "auto")) {
      verification.add("verify-bridge-roadie-opencode-plugins")
    }
  }

  if (overlays.homeboy) verification.add("verify-homeboy")
  if (profile.provider_path === "codebox-minions") verification.add("verify-codebox-provider")
  if (profile.provider_path === "external-openai-compatible-endpoint") verification.add("verify-wp-ai-gateway")

  return {
    summary: {
      target: installTarget,
      runtime_axis: runtime.selection,
      bridge_axis: effectiveBridge,
      overlays: Object.entries(overlays)
        .filter(([, value]) => value === true)
        .map(([key]) => key),
      systems_capabilities: systemsCapabilities.profile || "none",
      source_mode: source.mode,
      workspace_repositories: source.repositories,
    },
    commands: {
      dry_run: formatCommand(env, command, true),
      apply: formatCommand(env, command, false),
      ...(installTarget === "external-runtime"
        ? {
            start: formatCommand(
              { WP_CONTROL_TRANSPORT_JSON: env.WP_CONTROL_TRANSPORT_JSON },
              [`${target.runtime_project_root}/.wp-coding-agents/bin/roadie`]
            ),
          }
        : {}),
    },
    verification: {
      overlays: [...verification],
    },
    warnings,
  }
}

try {
  const profile = readJson()
  process.stdout.write(`${JSON.stringify(compile(profile), null, 2)}\n`)
} catch (error) {
  process.stderr.write(`${error.message}\n`)
  process.exit(1)
}
