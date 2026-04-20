---
name: upgrade-wp-coding-agents
description: "Safely upgrade wp-coding-agents on a live install — VPS or local — without touching user state. Syncs plugins, skills, AGENTS.md, systemd unit (VPS), and re-applies the claude-auth PascalCase patch."
compatibility: "Requires a wp-coding-agents repo clone and an existing setup. Works on VPS (systemd) and local installs (macOS launchd or manual)."
---

# Upgrade wp-coding-agents

**Purpose:** Pull the latest wp-coding-agents improvements onto a live install — new plugin versions, updated skills, regenerated AGENTS.md, systemd template fixes (VPS), and the opencode-claude-auth patch — without touching opencode config, WordPress, or agent memory.

The same `upgrade.sh` script handles both environments. It auto-detects and branches internally; you do not need to memorise paths.

## When to use

The user says something like:
- "Upgrade wp-coding-agents"
- "Pull the latest plugin fixes onto this install"
- "My dm-context-filter.ts is out of date"
- "Regenerate AGENTS.md from the latest template"

## Step 1 — Detect the environment

Before running anything, identify which side you are on. The script auto-detects, but you should know too so you can give the user the right restart instructions.

| Signal | VPS | Local |
|---|---|---|
| `/etc/systemd/system/kimaki.service` exists | yes | no |
| `command -v studio` succeeds | usually no | usually yes |
| Platform | Linux | macOS or Linux |
| Plugins land at | `/opt/kimaki-config/plugins` | `$(npm root -g)/kimaki/plugins` |
| Restart command | `systemctl restart kimaki` | `launchctl kickstart -k gui/$(id -u)/com.wp.kimaki` (launchd) or "stop the kimaki process" (manual) |

**On macOS the script auto-enables `--local`.** On Linux without `--local`, the script assumes VPS.

## Step 2 — Resolve the repo path

Never hardcode the workspace path. Use whichever clone the user has on disk:

```bash
# Inside the wp-coding-agents clone:
cd "$(git rev-parse --show-toplevel)"

# Or from a known checkout:
cd /path/to/wp-coding-agents
```

Then pull latest:

```bash
git pull origin main
```

> If the user maintains a fork or a feature branch, ask before pulling. Default is `origin/main`.

## Step 3 — Dry run

Always dry-run first on a live install. The dry-run never modifies anything.

**VPS:**
```bash
./upgrade.sh --dry-run
```

**Local:**
```bash
./upgrade.sh --dry-run --wp-path "/path/to/site"
# --local is auto on macOS; pass it explicitly on Linux local installs.
```

Review the diff output. If anything looks wrong (wrong runtime detected, unexpected unit rewrite, plugin paths point somewhere weird), stop and investigate before proceeding.

## Step 4 — Run the upgrade

Drop `--dry-run`:

**VPS:**
```bash
./upgrade.sh
```

**Local:**
```bash
./upgrade.sh --wp-path "/path/to/site"
```

Backups are written next to each touched file with a timestamp suffix. On VPS that means `/opt/kimaki-config.backup.<ts>`, `AGENTS.md.backup.<ts>`, `kimaki.service.backup.<ts>`. On local, the kimaki-config backup lands under `$KIMAKI_DATA_DIR/backups/` (defaults to `~/.kimaki/backups/`).

On local, `upgrade.sh` also runs `post-upgrade.sh` inline to enforce the skills kill list against the npm-installed kimaki package — VPS gets this on the next `systemctl restart kimaki` via the unit's `ExecStartPre`.

## Step 5 — Verify

The script's summary block prints the right verify commands for the detected environment. Run them and sanity-check.

**VPS verify:**
```bash
systemctl status kimaki
diff -u /opt/kimaki-config/plugins/dm-context-filter.ts \
        "$(git -C /path/to/wp-coding-agents rev-parse --show-toplevel)/kimaki/plugins/dm-context-filter.ts"
head -20 /var/www/*/AGENTS.md
```

**Local verify:**
```bash
# launchd (auto-installed on macOS):
launchctl print "gui/$(id -u)/com.wp.kimaki" | head -20
# or, if running kimaki manually:
pgrep -fl kimaki

NPM_ROOT="$(npm root -g)"
diff -u "$NPM_ROOT/kimaki/plugins/dm-context-filter.ts" \
        "$(git -C /path/to/wp-coding-agents rev-parse --show-toplevel)/kimaki/plugins/dm-context-filter.ts"
head -20 /path/to/site/AGENTS.md
```

## Step 6 — Tell the user to restart kimaki

The upgrade script never restarts the chat bridge automatically — active Discord sessions would die mid-turn. Hand the right command to the user based on what was detected:

- **VPS:** `systemctl restart kimaki`
- **Local launchd (macOS):** `launchctl kickstart -k gui/$(id -u)/com.wp.kimaki`
- **Local manual:** stop the running kimaki process and re-launch with `cd <site> && kimaki`

> Always say something like: *"Restart kimaki when ready — active sessions will die."* Let the user pick the moment.

## Scope flags

These work in both VPS and local mode:

- `--kimaki-only` — only sync the kimaki config + plugins
- `--skills-only` — only refresh agent skills (WordPress/agent-skills + Extra-Chill/data-machine-skills)
- `--agents-md-only` — only regenerate AGENTS.md via `datamachine agent compose`

## Never do

- Never restart kimaki automatically. Always let the user decide.
- Never touch `opencode.json`, the WordPress DB, nginx, SSL certs, `~/.kimaki/` auth state and OAuth tokens, the DM workspace cloned repos, or agent memory files (`SOUL.md` / `MEMORY.md` / `USER.md`).
- Never run without a dry-run first on a live install.
- Never hardcode `/var/lib/...`, `/opt/...`, `/var/www/...`, or `/root/...` paths in the steps you give the user. Use `git rev-parse --show-toplevel`, `$(npm root -g)`, `$KIMAKI_DATA_DIR`, and the script's auto-detection.
