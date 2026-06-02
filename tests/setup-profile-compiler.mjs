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
