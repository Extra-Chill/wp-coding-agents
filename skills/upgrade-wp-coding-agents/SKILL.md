---
name: upgrade-wp-coding-agents
description: "Safely upgrade wp-coding-agents on a live install — VPS or local — without touching user state. Syncs plugins, skills, AGENTS.md, and service files for the detected environment."
compatibility: "Requires a wp-coding-agents repo clone and an existing setup. Works on VPS (systemd) and local installs (macOS launchd or manual)."
---

# Upgrade wp-coding-agents

`upgrade.sh` already auto-detects the environment, picks the chat bridge, applies the managed sync, and emits the right verify + restart commands in its summary block. This skill exists for the **policy boundary** the script can't enforce on its own.

By default it updates the setup-installed Data Machine plugin (`data-machine`) and WP Codebox when their managed sources are present. Use `--skip-plugins` to preserve the previous no-plugin-update behavior.

If the install was created with the optional Homeboy layer, upgrade should preserve that model: the WordPress site root is the Homeboy **project**, declared repository checkouts are attached **components**, and `repo@branch` worktrees remain skipped by default. Homeboy is external to wp-coding-agents; do not vendor it or treat the site root as a component during upgrade guidance.

Setup uses the one-shot guide at `operator-entrypoints/wp-coding-agents-setup/setup.md`, plus `operator-entrypoints/wp-coding-agents-setup/interview.md` and `scripts/compile-setup-profile.mjs`, to map a new install profile into commands. Upgrade intentionally does **not** duplicate that compiler: `upgrade.sh` owns detection, bridge selection, apply-time sync, and summary commands for an already-installed environment.

## When to use

The user says something like:
- "Upgrade wp-coding-agents"
- "Pull the latest plugin fixes onto this install"
- "My dm-context-filter.ts is out of date"
- "Regenerate AGENTS.md from the latest template"

## Procedure

1. **Find the repo and pull main:**
   ```bash
   cd "$(git -C ~/Developer/wp-coding-agents rev-parse --show-toplevel)"
   git pull origin main
   ```
   If the user maintains a fork or a feature branch, ask before pulling. Default is `origin/main`.

2. **Run the upgrade directly.**
   ```bash
   ./upgrade.sh                      # VPS
   ./upgrade.sh --wp-path /path      # local (auto-set on macOS)
   ```
   Read the output. Stop and investigate if anything fails or looks wrong (wrong runtime, unexpected unit rewrite, plugin paths point somewhere weird).

3. **Restart the detected chat bridge.** The script prints the exact restart command for the detected bridge × environment. For managed Kimaki services, run it from the active thread's tool shell: the bridge-owned helper records only bounded identity, route IDs, typed checks, and the next-action enum, then detaches before restarting. Startup atomically consumes the record and sends one fixed resume event to the original thread. Delivery is at-most-once: an ambiguous dispatch failure is never replayed automatically. Inspect `restart-status.json` or `resume-status.json` under `$KIMAKI_DATA_DIR/kimaki-config/restart-continuation/`; failed restart status includes the credential-free `recovery_command`. If restart or resume fails, report incomplete work and use that explicit recovery evidence rather than rerunning upgrade mutations.

4. **After restart, verify Kimaki's OpenCode plugins when Kimaki + OpenCode are in use.** The summary's verify block checks the managed plugin files. Run it, then inspect the Kimaki startup logs for `kimaki-config: WARNING:` lines. Any warning about a missing persistent plugin source dir or missing required OpenCode plugin means `opencode.json` may reference plugin files OpenCode silently skipped.

5. **Verify the filter behavior from the repo when available.** Run:
   ```bash
   node tests/effective-prompt/run.mjs
   ```
   Passing output (`OK — ... scenario(s)`) proves `dm-context-filter` still replaces Kimaki's generic prompt with the managed bridge prompt while preserving unrelated system blocks. If this fails after a Kimaki upgrade, fix the filter or refresh snapshots intentionally before calling the upgrade healthy.

6. **Verify Homeboy when the install uses it.** Only do this when the user enabled Homeboy or `AGENTS.md` contains the Homeboy section. Run the project/component checks and pass failures through clearly:
   ```bash
   homeboy --version
   homeboy extension list
    homeboy extension show wordpress
    homeboy config show --format=json | jq -e '.data.config.worktree_providers.dmc == null and .data.config.settings.worktree_provider_lifecycle.dmc == null'
    homeboy project show <project-id>
   homeboy project components list <project-id>
   wp config get DATAMACHINE_COMPOSE_AGENTS_MD --path=/path/to/site
   wp datamachine memory compose AGENTS.md --path=/path/to/site
   ```
   For WordPress Studio installs, run:
   ```bash
   studio wp datamachine memory compose AGENTS.md
   ```
     Homeboy is the sole lifecycle owner. Attribute extension readiness and project/component lookup failures to Homeboy. Do not create `homeboy.json` in the site root to "fix" a missing project; that confuses a Homeboy project with a component.

   Setup and upgrade write `define( 'DATAMACHINE_COMPOSE_AGENTS_MD', true )` to wp-config.php (idempotent grep-guard; skipped on Studio and dry-run). This is the gate that turns on core-owned AGENTS.md composition — `wp config get DATAMACHINE_COMPOSE_AGENTS_MD` should return `true` after either run.

Run `./upgrade.sh --help` for scope flags (`--plugins-only`, `--skip-plugins`, `--kimaki-only`, `--skills-only`, `--agents-md-only`, `--repair-opencode-json`, etc.) and the full list of what the script touches and never touches.

## Never do

- **Never leave the chat bridge running after a successful upgrade.** Restart it with the summary command so managed config changes take effect.
- **Never touch user state:** `opencode.json` (the script does additive-only repair), the WordPress DB, nginx, SSL certs, `~/.kimaki/` auth state and OAuth tokens, the DM workspace cloned repos, or agent memory files (`SOUL.md` / `MEMORY.md` / `USER.md`).
- **Never vendor Homeboy** into wp-coding-agents or scaffold `homeboy.json` in the WordPress site root. The site root is a Homeboy project; component metadata belongs in attached primary workspace repos.
- **Never auto-attach `@` worktrees** as Homeboy components during upgrade. They are task-specific worktrees and are skipped by default.
- **Never hardcode workspace paths** (`/var/lib/...`, `/opt/...`, `/var/www/...`, `/root/...`) in commands you give the user. Use `git rev-parse --show-toplevel`, `$(npm root -g)`, `$KIMAKI_DATA_DIR`, and the script's auto-detection.

## Source of truth

| Question | Where to look |
|---|---|
| What flags exist? | `./upgrade.sh --help` |
| What did the upgrade actually do? | The script's summary block (printed at the end of every run) |
| What's the right restart command for this bridge × env? | The summary block — rendered from `bridges/<name>.sh::bridge_restart_cmd`; managed Kimaki commands require the active thread route injected into the tool shell |
| What's the right verify command? | The summary block |
| What chat bridges are supported? | `bridges/_dispatch.sh::bridge_names` (auto-discovered from `bridges/*.sh` — currently kimaki, cc-connect, telegram) |
