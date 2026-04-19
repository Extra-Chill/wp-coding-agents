---
name: upgrade-wp-coding-agents
description: "Safely upgrade wp-coding-agents infrastructure on a live VPS without touching user state. Syncs plugins, skills, AGENTS.md, systemd unit, and re-applies the claude-auth PascalCase patch."
compatibility: "Requires wp-coding-agents repo clone and an existing setup. Works on VPS (systemd) and local installs."
---

# Upgrade wp-coding-agents

**Purpose:** Pull the latest wp-coding-agents improvements onto a live install — new plugin versions, updated skills, regenerated AGENTS.md, systemd template fixes, and the opencode-claude-auth patch — without touching opencode config, WordPress, or agent memory.

## When to use

The user says something like:
- "Upgrade wp-coding-agents"
- "Pull the latest plugin fixes to this VPS"
- "My dm-context-filter.ts is out of date"
- "Regenerate AGENTS.md from the latest template"

## Steps

1. **Pull latest wp-coding-agents code.**
   ```bash
   cd /var/lib/datamachine/workspace/wp-coding-agents
   git pull origin main
   ```

2. **Preview with a dry run.** This never modifies anything — it just shows you what would change.
   ```bash
   ./upgrade.sh --dry-run
   ```
   Review the diff output. If anything looks wrong (wrong runtime detected, unexpected kimaki.service rewrite, etc.), stop and investigate.

3. **Run the upgrade for real.**
   ```bash
   ./upgrade.sh
   ```
   Backups of `/opt/kimaki-config`, `AGENTS.md`, and `kimaki.service` are written alongside the originals with a timestamp suffix.

4. **Verify.**
   ```bash
   diff -u /opt/kimaki-config/plugins/dm-context-filter.ts \
           /var/lib/datamachine/workspace/wp-coding-agents/kimaki/plugins/dm-context-filter.ts
   head -20 /var/www/*/AGENTS.md
   ls /root/.kimaki/projects/*/skills 2>/dev/null || ls /var/www/*/.opencode/skills
   systemctl status kimaki
   ```

5. **Tell the user to restart kimaki when ready.** The upgrade script never restarts the service automatically — active Discord sessions would be killed.
   > "Restart kimaki when ready: `systemctl restart kimaki` (active sessions will die)."

## Scope flags

- `--kimaki-only` — only sync `/opt/kimaki-config` (plugins, post-upgrade.sh, kill list)
- `--skills-only` — only refresh agent skills from WordPress/agent-skills + Extra-Chill/data-machine-skills
- `--agents-md-only` — only regenerate AGENTS.md via `datamachine agent compose`

## Never do

- Never restart the kimaki service automatically. Always let the user decide.
- Never touch `opencode.json`, WordPress DB, nginx, SSL certs, `~/.kimaki/` auth state, `/var/lib/datamachine/workspace/` cloned repos, or agent memory files (SOUL.md / MEMORY.md / USER.md).
- Never run without a dry-run first on a live VPS.
