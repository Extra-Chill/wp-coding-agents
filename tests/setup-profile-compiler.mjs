import assert from "node:assert/strict"
import { execFileSync, spawnSync } from "node:child_process"

function compile(profile) {
  return JSON.parse(
    execFileSync("node", ["scripts/compile-setup-profile.mjs"], {
      input: JSON.stringify(profile),
      encoding: "utf8",
    })
  )
}

{
  const plan = compile({
    install_target: "external-runtime",
    target: {
      runtime_project_root: "/tmp/runtime root",
      wordpress_path: "/remote/site root",
      wordpress_user: "agent user",
      control_transport_argv: ["/usr/local/bin/control transport", "--identity", "value with spaces"],
    },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "kimaki" },
    provider_path: "external-openai-compatible-endpoint",
    overlays: {},
    agent: { slug: "remote" },
  })
  assert.match(plan.commands.apply, /RUNTIME_PROJECT_ROOT='\/tmp\/runtime root'/)
  assert.match(plan.commands.apply, /WP_CONTROL_TRANSPORT_JSON='\["\/usr\/local\/bin\/control transport","--identity","value with spaces"\]'/)
  assert.match(plan.commands.apply, /--external-wordpress --wordpress-path '\/remote\/site root' --wordpress-user 'agent user'/)
  assert.match(plan.commands.apply, /--with-ai-gateway/)
  assert.doesNotMatch(plan.commands.apply, /--source-mode/)
  assert.doesNotMatch(plan.commands.apply, /--workspace-repository/)
  assert.ok(plan.warnings.some((warning) => warning.includes("no new mutable repository authority")))
  assert.match(plan.commands.start, /WP_CONTROL_TRANSPORT_JSON=.*\/tmp\/runtime root\/\.wp-coding-agents\/bin\/roadie/)
  assert.ok(plan.verification.overlays.includes("verify-external-wordpress-transport"))
}

{
  const plan = compile({
    install_target: "existing-vps",
    target: { wordpress_path: "/var/www/example.com" },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "roadie" },
    overlays: {},
    systems_capabilities: { profile: "managed-vps" },
    agent: {},
  })
  assert.match(plan.commands.apply, /--systems-capabilities managed-vps/)
  assert.equal(plan.summary.systems_capabilities, "managed-vps")
  assert.doesNotMatch(plan.commands.apply, /--source-mode|--workspace-repository/)
}

{
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "local",
      target: { wordpress_path: "/tmp/site" },
      runtime: { selection: "opencode" },
      chat_bridge: { selection: "none" },
      overlays: {},
      systems_capabilities: { profile: "managed-vps" },
    }),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /requires a colocated VPS install/)
}

for (const selection of ["auto"]) {
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "external-runtime",
      target: {
        runtime_project_root: "/tmp/runtime",
        wordpress_path: "/remote/site",
        control_transport_argv: ["/usr/local/bin/control"],
      },
      runtime: { selection },
      chat_bridge: { selection: "none" },
      overlays: {},
    }),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /requires runtime\.selection=opencode/)
}

{
  const plan = compile({
    install_target: "local",
    target: { wordpress_path: "~/Studio/site", wordpress_studio: true },
    runtime: { selection: "opencode", runtimes: [] },
    chat_bridge: { selection: "roadie" },
    provider_path: "not-applicable",
    overlays: { homeboy: true, wordpress_studio: true },
    agent: { slug: "site" },
  })

  assert.equal(
    plan.commands.dry_run,
    'EXISTING_WP="$HOME/Studio/site" WP_CLI_TRANSPORT_JSON=\'["studio","wp"]\' ./setup.sh --local --runtime opencode --chat roadie --with-homeboy --agent-slug site --dry-run'
  )
  assert.ok(plan.verification.overlays.includes("verify-wordpress-studio"))
  assert.ok(plan.verification.overlays.includes("verify-runtime-opencode"))
  assert.ok(plan.verification.overlays.includes("verify-bridge-roadie-opencode-plugins"))
  assert.ok(plan.verification.overlays.includes("verify-homeboy"))
}

{
  const plan = compile({
    install_target: "fresh-vps",
    target: { domain: "example.com" },
    runtime: { selection: "auto" },
    chat_bridge: { selection: "auto" },
    overlays: {},
    agent: {},
  })

  assert.equal(plan.commands.dry_run, "SITE_DOMAIN=example.com ./setup.sh --dry-run")
  assert.ok(plan.warnings.some((warning) => warning.includes("no new mutable repository authority")))
}

{
  const plan = compile({
    install_target: "fresh-vps",
    target: { domain: "network.example.com" },
    runtime: { selection: "auto" },
    chat_bridge: { selection: "none" },
    overlays: { subdomain_multisite: true },
    agent: {},
  })

  assert.equal(plan.commands.dry_run, "SITE_DOMAIN=network.example.com ./setup.sh --no-chat --multisite --subdomain --dry-run")
}


{
  const plan = compile({
    install_target: "local",
    target: { wordpress_path: "/tmp/site" },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "none" },
    overlays: {},
  })
  assert.equal(plan.summary.source_mode, "workspace")
  assert.deepEqual(plan.summary.workspace_repositories, [])
  assert.doesNotMatch(plan.commands.apply, /--workspace-repository/)
  assert.ok(plan.warnings.some((warning) => warning.includes("Legacy profile has no source declaration")))
}

{
  const plan = compile({
    install_target: "local",
    target: { wordpress_path: "/tmp/site" },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "none" },
    source: { mode: "workspace", workspace_repositories: ["/work/primary checkout", "/work/secondary"] },
    overlays: {},
  })
  assert.match(plan.commands.apply, /--source-mode workspace --workspace-repository '[/]work[/]primary checkout' --workspace-repository [/]+work[/]secondary/)
  assert.deepEqual(plan.summary.workspace_repositories, ["/work/primary checkout", "/work/secondary"])
  assert.ok(!plan.warnings.some((warning) => warning.includes("Legacy profile has no source declaration")))
}

{
  const plan = compile({
    install_target: "local",
    target: { wordpress_path: "/tmp/site" },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "none" },
    source: {
      mode: "workspace",
      workspace_repositories: [
        { path: "/work/new checkout", remote: "https://github.com/example/project.git" },
      ],
    },
    overlays: {},
  })
  assert.match(plan.commands.apply, /--workspace-repository-clone https:\/\/github\.com\/example\/project\.git '[/]work[/]new checkout'/)
  assert.deepEqual(plan.summary.workspace_repositories, ["/work/new checkout"])
  assert.deepEqual(plan.summary.workspace_repository_clones, [
    { path: "/work/new checkout", remote: "https://github.com/example/project.git" },
  ])
}

for (const source of [
  null,
  { mode: "workspace" },
  { mode: "workspace", workspace_repositories: [] },
  { mode: "workspace", workspace_repositories: ["relative"] },
  { mode: "workspace", workspace_repositories: ["/work/repo", "/work/repo"] },
  { mode: "workspace", workspace_repositories: [{ path: "/work/repo", remote: "https://token@example.com/repo.git" }] },
  { mode: "workspace", workspace_repositories: [{ path: "/work/repo", remote: "ssh://git:secret@example.com/repo.git" }] },
  { mode: "owned", workspace_repositories: ["/work/repo"] },
]) {
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "local",
      target: { wordpress_path: "/tmp/site" },
      runtime: { selection: "opencode" },
      chat_bridge: { selection: "none" },
      source,
      overlays: {},
    }),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
}

{
  const plan = compile({
    install_target: "local",
    target: { wordpress_path: "/tmp/site" },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "none" },
    source: { mode: "owned", workspace_repositories: [] },
    overlays: {},
  })
  assert.doesNotMatch(plan.commands.apply, /--workspace-repository/)
}


{
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "local",
      target: { wordpress_path: "/tmp/site" },
      runtime: { selection: "opencode,pi" },
      chat_bridge: { selection: "none" },
      overlays: {},
    }),
    encoding: "utf8",
  })

  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /Unknown runtime: opencode,pi/)
}

// Codex and Claude Code were removed (#751) and fail with a migration note.
for (const selection of ["codex", "claude-code", "multiple"]) {
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "local",
      target: { wordpress_path: "/tmp/site" },
      runtime: { selection },
      chat_bridge: { selection: "none" },
      overlays: {},
    }),
    encoding: "utf8",
  })

  assert.notEqual(result.status, 0)
  if (selection === "multiple") {
    assert.match(result.stderr, /Unknown runtime: multiple/)
  } else {
    assert.match(result.stderr, new RegExp(`runtime\\.selection '${selection}' was removed \\(wp-coding-agents#751\\)`))
  }
}

{
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "local",
      target: { wordpress_path: "/tmp/site" },
      runtime: { selection: "opencode" },
      chat_bridge: { selection: "none" },
      codex_path: "codebox-minions",
      overlays: {},
    }),
    encoding: "utf8",
  })

  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /codex_path was renamed provider_path/)
}

console.log("OK: setup profile compiler")
