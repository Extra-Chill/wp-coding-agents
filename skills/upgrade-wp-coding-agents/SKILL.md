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

## Step 1 — Detect the environment and chat bridge

Before running anything, identify (a) which side you are on and (b) which chat bridge is installed. The script auto-detects both, but you should know too so you can give the user the right restart instructions.

### Environment signals

| Signal | VPS | Local |
|---|---|---|
| `/etc/systemd/system/<bridge>.service` exists | yes | no |
| `command -v studio` succeeds | usually no | usually yes |
| Platform | Linux | macOS or Linux |

**On macOS the script auto-enables `--local`.** On Linux without `--local`, the script assumes VPS.

### Supported chat bridges

`upgrade.sh` auto-detects one of three chat bridges based on installed service files or binaries:

| Bridge | VPS unit(s) | Local launchd plist(s) | Per-install artifacts |
|---|---|---|---|
| **kimaki** | `kimaki.service` | `com.wp.kimaki.plist` | `/opt/kimaki-config/` on VPS; `$(npm root -g)/kimaki/plugins` + `$KIMAKI_DATA_DIR/kimaki-config/` on local |
| **cc-connect** | `cc-connect.service` | `com.wp.cc-connect.plist` | none (user owns `$HOME/.cc-connect/config.toml`) |
| **telegram** | `opencode-serve.service` + `opencode-telegram.service` | `com.wp.opencode-serve.plist` + `com.wp.opencode-telegram.plist` | none (user owns `.env` files under `$HOME/.config/opencode-*/`) |

Ordering matches install priority: kimaki > cc-connect > telegram if more than one is installed.

### Restart commands

Do not guess restart commands. The script's summary block prints the exact command for the detected bridge × environment combination at the end of every run — pass that through to the user verbatim. The source of truth for these commands is `lib/chat-bridges.sh::bridge_restart_cmd`; they are rendered once and reused by both `upgrade.sh` and setup-time summary output, so the skill never needs its own copy.

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

### Persistent skill source

`--skills-only` (and a full run) also mirrors every installed skill into the persistent kimaki-config skill source dir. This is the durable copy that survives `npm update -g kimaki` wipes of `$(npm root -g)/kimaki/skills/`:

- **Local:** `$KIMAKI_DATA_DIR/kimaki-config/skills/` (defaults to `~/.kimaki/kimaki-config/skills/`)
- **VPS:** `/opt/kimaki-config/skills/`

On local, `upgrade.sh` runs `post-upgrade.sh` inline. On VPS, `kimaki.service`'s `ExecStartPre` runs it on next service start. `post-upgrade.sh` performs two symmetric passes against `$(npm root -g)/kimaki/skills/`: (1) remove the unwanted bundled skills listed in `skills-kill-list.txt`, and (2) restore the wp-coding-agents skills from the persistent source dir. Both passes are idempotent and run on every kimaki restart.

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

## Step 6 — Tell the user to restart the chat bridge

The upgrade script never restarts the chat bridge automatically — active chat sessions would die mid-turn. Hand the right command to the user based on what the summary block printed. See the restart-command table in Step 1.

> Always say something like: *"Restart &lt;bridge&gt; when ready — active sessions will die."* Let the user pick the moment. For the telegram bridge there are two services (`opencode-serve` + `opencode-telegram`) — restart both, in that order.

## Scope flags

These work in both VPS and local mode:

- `--kimaki-only` — only sync the chat-bridge config (name kept for backwards compatibility — also handles cc-connect and telegram when they are the detected bridge)
- `--skills-only` — only refresh agent skills (WordPress/agent-skills + Extra-Chill/data-machine-skills)
- `--agents-md-only` — only regenerate AGENTS.md via `datamachine agent compose`

## Never do

- Never restart kimaki automatically. Always let the user decide.
- Never touch `opencode.json`, the WordPress DB, nginx, SSL certs, `~/.kimaki/` auth state and OAuth tokens, the DM workspace cloned repos, or agent memory files (`SOUL.md` / `MEMORY.md` / `USER.md`).
- Never run without a dry-run first on a live install.
- Never hardcode `/var/lib/...`, `/opt/...`, `/var/www/...`, or `/root/...` paths in the steps you give the user. Use `git rev-parse --show-toplevel`, `$(npm root -g)`, `$KIMAKI_DATA_DIR`, and the script's auto-detection.
