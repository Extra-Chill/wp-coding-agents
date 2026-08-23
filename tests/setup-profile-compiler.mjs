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
    codex_path: "external-openai-compatible-endpoint",
    overlays: {},
    agent: { slug: "remote" },
  })
  assert.match(plan.commands.apply, /RUNTIME_PROJECT_ROOT='\/tmp\/runtime root'/)
  assert.match(plan.commands.apply, /WP_CONTROL_TRANSPORT_JSON='\["\/usr\/local\/bin\/control transport","--identity","value with spaces"\]'/)
  assert.match(plan.commands.apply, /--external-wordpress --wordpress-path '\/remote\/site root' --wordpress-user 'agent user'/)
  assert.match(plan.commands.apply, /--with-ai-gateway/)
  assert.match(plan.commands.start, /WP_CONTROL_TRANSPORT_JSON=.*\/tmp\/runtime root\/\.wp-coding-agents\/bin\/kimaki/)
  assert.ok(plan.verification.overlays.includes("verify-external-wordpress-transport"))
}

{
  const plan = compile({
    install_target: "existing-vps",
    target: { wordpress_path: "/var/www/example.com" },
    runtime: { selection: "opencode" },
    chat_bridge: { selection: "kimaki" },
    overlays: {},
    systems_capabilities: { profile: "managed-vps" },
    agent: {},
  })
  assert.match(plan.commands.apply, /--systems-capabilities managed-vps/)
  assert.equal(plan.summary.systems_capabilities, "managed-vps")
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

for (const selection of ["auto", "codex", "claude-code", "multiple"]) {
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "external-runtime",
      target: {
        runtime_project_root: "/tmp/runtime",
        wordpress_path: "/remote/site",
        control_transport_argv: ["/usr/local/bin/control"],
      },
      runtime: { selection, runtimes: selection === "multiple" ? ["opencode", "codex"] : [] },
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
    chat_bridge: { selection: "kimaki" },
    codex_path: "not-applicable",
    overlays: { homeboy: true, wordpress_studio: true },
    agent: { slug: "site" },
  })

  assert.equal(
    plan.commands.dry_run,
    'EXISTING_WP="$HOME/Studio/site" WP_CMD=\'studio wp\' ./setup.sh --local --runtime opencode --chat kimaki --with-homeboy --agent-slug site --dry-run'
  )
  assert.ok(plan.verification.overlays.includes("verify-wordpress-studio"))
  assert.ok(plan.verification.overlays.includes("verify-runtime-opencode"))
  assert.ok(plan.verification.overlays.includes("verify-bridge-kimaki-opencode-plugins"))
  assert.ok(plan.verification.overlays.includes("verify-homeboy"))
}

{
  const plan = compile({
    install_target: "fresh-vps",
    target: { domain: "example.com" },
    runtime: { selection: "multiple", runtimes: ["claude-code", "opencode"] },
    chat_bridge: { selection: "auto" },
    overlays: {},
    agent: {},
  })

  assert.equal(plan.commands.dry_run, "SITE_DOMAIN=example.com ./setup.sh --dry-run")
  assert.ok(plan.warnings.some((warning) => warning.includes("Multiple runtimes")))
  assert.ok(plan.verification.overlays.includes("verify-runtime-multiple"))
  assert.ok(plan.verification.overlays.includes("verify-runtime-claude-code"))
  assert.ok(plan.verification.overlays.includes("verify-runtime-opencode"))
  assert.deepEqual(plan.follow_up_commands, ["EXISTING_WP=/var/www/example.com ./setup.sh --runtime-only --runtime opencode"])
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
    target: { wordpress_path: "/Users/chubes/Studio/site" },
    runtime: { selection: "codex" },
    chat_bridge: { selection: "auto" },
    overlays: {},
    agent: {},
  })

  assert.equal(plan.commands.dry_run, "EXISTING_WP=/Users/chubes/Studio/site ./setup.sh --local --runtime codex --dry-run")
  assert.equal(plan.summary.bridge_axis, "none")
  assert.ok(plan.verification.overlays.includes("verify-runtime-codex"))
  assert.ok(plan.verification.overlays.includes("verify-bridge-none"))
}

{
  const plan = compile({
    install_target: "local",
    target: { wordpress_path: "/home/chris/site" },
    runtime: { selection: "multiple", runtimes: ["opencode", "claude-code"] },
    chat_bridge: { selection: "none" },
    overlays: {},
    agent: {},
  })

  assert.deepEqual(plan.follow_up_commands, ["EXISTING_WP=/home/chris/site ./setup.sh --local --runtime-only --runtime claude-code"])
}

{
  const result = spawnSync("node", ["scripts/compile-setup-profile.mjs"], {
    input: JSON.stringify({
      install_target: "local",
      target: { wordpress_path: "/tmp/site" },
      runtime: { selection: "claude-code,opencode" },
      chat_bridge: { selection: "none" },
      overlays: {},
    }),
    encoding: "utf8",
  })

  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /Unknown runtime: claude-code,opencode/)
}

console.log("OK: setup profile compiler")
