---
name: upgrade-wp-coding-agents
description: "Safely upgrade wp-coding-agents on a live install — VPS or local — without touching user state. Syncs plugins, skills, AGENTS.md, systemd unit (VPS), and re-applies the claude-auth PascalCase patch."
compatibility: "Requires a wp-coding-agents repo clone and an existing setup. Works on VPS (systemd) and local installs (macOS launchd or manual)."
---

# Upgrade wp-coding-agents

`upgrade.sh` already auto-detects the environment, picks the chat bridge, prints a diff in dry-run, and emits the right verify + restart commands in its summary block. This skill exists for the **policy boundary** the script can't enforce on its own.

By default it also updates the setup-installed Data Machine plugins (`data-machine`, `data-machine-code`) to their latest version tags when those plugins are git checkouts. Use `--skip-plugins` to preserve the previous no-plugin-update behavior.

If the install was created with the optional Homeboy layer, upgrade should preserve that model: the WordPress site root is the Homeboy **project**, primary Data Machine Code workspace checkouts are attached **components**, and `repo@branch` worktrees remain skipped by default. Homeboy is external to wp-coding-agents; do not vendor it or treat the site root as a component during upgrade guidance.

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

2. **Dry-run first.** Always.
   ```bash
   ./upgrade.sh --dry-run                      # VPS
   ./upgrade.sh --dry-run --wp-path /path      # local (auto-set on macOS)
   ```
   Read the output. Stop and investigate if anything looks wrong (wrong runtime, unexpected unit rewrite, plugin paths point somewhere weird).

3. **Apply** by dropping `--dry-run`. The script prints a summary with the exact verify + restart commands for the detected bridge × environment. Pass them through to the user verbatim — do not paraphrase, do not guess.

4. **Tell the user to restart the chat bridge themselves.** Active chat sessions die on restart, so the user picks the moment.

5. **After restart, verify Kimaki's OpenCode plugins when Kimaki + OpenCode are in use.** The summary's verify block includes a `test -f .../dm-context-filter.ts && test -f .../dm-agent-sync.ts` command. Run it or ask the user to run it, then inspect the Kimaki startup logs for `kimaki-config: WARNING:` lines. Any warning about a missing persistent plugin source dir or missing required OpenCode plugin means `opencode.json` may reference plugin files OpenCode silently skipped.

6. **Verify the filter behavior from the repo when available.** Run:
   ```bash
   node tests/effective-prompt/run.mjs
   ```
   Passing output (`OK — ... scenario(s)`) proves `dm-context-filter` still strips the Kimaki-only prompt sections the Data Machine agent should not see. If this fails after a Kimaki upgrade, fix the filter or refresh snapshots intentionally before calling the upgrade healthy.

7. **Verify Homeboy when the install uses it.** Only do this when the user enabled Homeboy or `AGENTS.md` contains the Homeboy section. Run the project/component checks and pass failures through clearly:
   ```bash
   homeboy --version
   homeboy extension list
   homeboy project show <project-id>
   homeboy project components list <project-id>
   wp option get datamachine_code_homeboy_available --path=/path/to/site
   wp datamachine memory compose AGENTS.md --path=/path/to/site
   ```
   For WordPress Studio installs, use `studio wp option get datamachine_code_homeboy_available` and `studio wp datamachine memory compose AGENTS.md`. Do not create `homeboy.json` in the site root to "fix" a missing project; that confuses a Homeboy project with a component.

Run `./upgrade.sh --help` for scope flags (`--plugins-only`, `--skip-plugins`, `--kimaki-only`, `--skills-only`, `--agents-md-only`, `--repair-opencode-json`, etc.) and the full list of what the script touches and never touches.

## Never do

- **Never restart the chat bridge automatically.** It kills active sessions including the one you're talking in.
- **Never skip the dry-run** on a live install.
- **Never touch user state:** `opencode.json` (the script does additive-only repair), the WordPress DB, nginx, SSL certs, `~/.kimaki/` auth state and OAuth tokens, the DM workspace cloned repos, or agent memory files (`SOUL.md` / `MEMORY.md` / `USER.md`).
- **Never vendor Homeboy** into wp-coding-agents or scaffold `homeboy.json` in the WordPress site root. The site root is a Homeboy project; component metadata belongs in attached primary workspace repos.
- **Never auto-attach `@` worktrees** as Homeboy components during upgrade. They are task-specific DMC worktrees and are skipped by default.
- **Never hardcode workspace paths** (`/var/lib/...`, `/opt/...`, `/var/www/...`, `/root/...`) in commands you give the user. Use `git rev-parse --show-toplevel`, `$(npm root -g)`, `$KIMAKI_DATA_DIR`, and the script's auto-detection.

## Source of truth

| Question | Where to look |
|---|---|
| What flags exist? | `./upgrade.sh --help` |
| What did the upgrade actually do? | The script's summary block (printed at the end of every run) |
| What's the right restart command for this bridge × env? | The summary block — rendered from `bridges/<name>.sh::bridge_restart_cmd` |
| What's the right verify command? | The summary block |
| What chat bridges are supported? | `bridges/_dispatch.sh::bridge_names` (auto-discovered from `bridges/*.sh` — currently kimaki, cc-connect, telegram) |
