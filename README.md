# WP Coding Agents

**A lean, composable AI agent on WordPress — VPS or local.**

wp-coding-agents puts an AI coding agent on any WordPress install with WordPress as its operating layer. Pick your runtime — [OpenCode](https://opencode.ai), [Claude Code](https://docs.anthropic.com/en/docs/claude-code), or [Studio Code](https://developer.wordpress.com/studio/) — and the script handles the rest. [Data Machine](https://github.com/Extra-Chill/data-machine) handles memory and scheduling, and a pluggable chat bridge ([Kimaki](https://kimaki.xyz) for Discord, [cc-connect](https://github.com/nichochar/cc-connect) for multi-platform, [opencode-telegram](https://github.com/grinev/opencode-telegram-bot) for Telegram, or none) handles communication. The agent's context window stays clean — no overhead for systems it's not using.

Runs on a dedicated VPS for always-on autonomous operation, or locally on your Mac/Linux machine for development and personal use.

## How It Works

```
 You (Discord / cc-connect / Telegram / SSH)
   │
   ▼
 Chat bridge (Kimaki, cc-connect, Telegram, or direct)
   │
   ▼
 Coding agent (OpenCode, Claude Code, or Studio Code)
   │
   ├── Config ──────── opencode.json / CLAUDE.md
   ├── SOUL.md ─────── identity (who am I?)
   ├── USER.md ─────── human profile (who am I helping?)
   ├── MEMORY.md ───── accumulated knowledge
   │
   ├── WP-CLI ──────── WordPress control
   └── Data Machine ── self-scheduling + AI tools
```

On activation, Data Machine creates a default agent and scaffolds its memory files. Additional agents get their own files when created. Every registered file is injected into each session — the agent wakes up knowing who it is and what it's been working on. No memory management overhead in the context window.

## Runtime Auto-Discovery

Drop a file in `runtimes/`, it's available. The script scans `runtimes/*.sh` for available runtimes and auto-detects which one to use based on what's installed:

```
hooks/
└── dm-agent-sync.sh   # SessionStart hook: sync DM agents into CLAUDE.md
runtimes/
├── opencode.sh        # OpenCode: opencode.json + AGENTS.md + {file:} includes
├── claude-code.sh     # Claude Code: CLAUDE.md + @ includes + .mcp.json
└── studio-code.sh     # Studio Code: CLAUDE.md + @ includes + Studio tools
```

Each runtime implements the same interface — install, config generation, MCP merge, skills directory. Adding a new runtime means implementing those functions in a single file.

## Standalone or Fleet

wp-coding-agents works in two modes with the same setup:

**Standalone** — Data Machine handles autonomy. The agent self-schedules flows, queues tasks, runs on cron. No orchestrator needed.

**Fleet member** — An orchestrator routes tasks via Agent Ping webhooks and Discord mentions. The agent executes on its own site, reports back. Multiple agents, each focused on their own WordPress site.

```
 Orchestrator (fleet-wide context)
   ├── Agent Ping / @mention ──▶  agent @ site-a.com
   ├── Agent Ping / @mention ──▶  agent @ site-b.com
   └── Agent Ping / @mention ──▶  agent @ site-c.com
```

This isn't theoretical. It's running in production right now — agents on separate VPS instances, each with their own WordPress site, coordinated through Discord and DM webhooks.

## Quick Start

### Local (macOS / Linux Desktop)

Works with any existing WordPress install — [WordPress Studio](https://developer.wordpress.com/studio/), MAMP, manual, etc.

```bash
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents

# OpenCode (auto-detected if installed)
EXISTING_WP=~/Studio/my-wordpress-website ./setup.sh --local

# Claude Code
EXISTING_WP=~/Studio/my-wordpress-website ./setup.sh --local --runtime claude-code

# Studio Code (auto-detected in WordPress Studio sites)
EXISTING_WP=~/Studio/my-wordpress-website ./setup.sh --local --runtime studio-code
```

On macOS, `--local` is auto-detected. The script installs Data Machine, the coding agent, agent skills, and optionally a chat bridge — no infrastructure, no root, no systemd.

Start your agent:

```bash
cd ~/Studio/my-wordpress-website && opencode      # OpenCode terminal
cd ~/Studio/my-wordpress-website && claude         # Claude Code terminal
cd ~/Studio/my-wordpress-website && studio code    # Studio Code terminal
cd ~/Studio/my-wordpress-website && kimaki         # OpenCode + Discord
```

### VPS

#### Let Your Agent Do It

Add the `wp-coding-agents-setup` skill to your local coding agent (Claude Code, Cursor, etc.):

```
skills/wp-coding-agents-setup/
```

Then: "Help me set up wp-coding-agents on my VPS"

Your local agent SSHs into the server, runs the setup, and your VPS agent wakes up.

#### Manual

```bash
ssh root@your-server-ip
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents
SITE_DOMAIN=yourdomain.com ./setup.sh
systemctl start kimaki  # or: systemctl start cc-connect
```

## Setup Options

| Flag | Description |
|------|-------------|
| `--runtime <name>` | Coding agent runtime: `opencode` (default), `claude-code`, `studio-code`. Auto-detected if omitted. |
| `--local` | Local machine mode — skip infrastructure (no apt, nginx, systemd, SSL). Auto-detected on macOS. |
| `--existing` | Add to existing WordPress (skip WP install) |
| `--wp-path <path>` | Path to WordPress root (implies `--existing`) |
| `--agent-slug <slug>` | Override Data Machine agent slug (default: derived from domain) |
| `--no-chat` | Skip chat bridge |
| `--chat <bridge>` | Chat bridge: `kimaki` (Discord, default for OpenCode), `cc-connect` (default for Claude Code and Studio Code), `telegram` |
| `--multisite` | Convert to WordPress Multisite (subdirectory by default) |
| `--subdomain` | Subdomain multisite (use with `--multisite`, requires wildcard DNS) |
| `--no-skills` | Skip WordPress agent skills |
| `--skip-deps` | Skip apt packages |
| `--skip-ssl` | Skip SSL/HTTPS |
| `--root` | Run agent as root (default on VPS) |
| `--non-root` | Run agent as dedicated service user |
| `--dry-run` | Print commands without executing |

### Examples

```bash
# Local: WordPress Studio + OpenCode + DM + Discord
EXISTING_WP=~/Studio/my-site ./setup.sh --local

# Local: Claude Code + DM + cc-connect
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime claude-code

# Local: Studio Code + DM (auto-detected in Studio sites)
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime studio-code

# Local: no chat bridge (terminal only)
EXISTING_WP=~/Studio/my-site ./setup.sh --local --no-chat

# VPS: Full setup with OpenCode (WordPress + DM + Discord)
SITE_DOMAIN=example.com ./setup.sh

# VPS: Claude Code
SITE_DOMAIN=example.com ./setup.sh --runtime claude-code

# VPS: Telegram instead of Discord
SITE_DOMAIN=example.com TELEGRAM_BOT_TOKEN=xxx TELEGRAM_ALLOWED_USER_ID=123 ./setup.sh --chat telegram

# VPS: Existing WordPress site
EXISTING_WP=/var/www/mysite ./setup.sh --existing

# VPS: Multisite network (subdomain)
SITE_DOMAIN=example.com ./setup.sh --multisite --subdomain

# Dry run (works with any mode)
SITE_DOMAIN=example.com ./setup.sh --dry-run
```

## What Gets Installed

| Component | Role | Optional? |
|-----------|------|-----------|
| **WordPress** | Site platform, WP-CLI access | No (existing install on local) |
| **[OpenCode](https://opencode.ai)**, **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)**, or **[Studio Code](https://developer.wordpress.com/studio/)** | AI coding agent runtime | Selected via `--runtime` |
| **[Data Machine](https://github.com/Extra-Chill/data-machine)** | Memory (SOUL/USER/MEMORY.md), self-scheduling, AI tools, Agent Ping | No — wp-coding-agents composes on top of DM |
| **[Data Machine Code](https://github.com/Extra-Chill/data-machine-code)** | Workspace management, GitHub integration, git operations | Installed with Data Machine |
| **[Kimaki](https://kimaki.xyz)**, **[cc-connect](https://github.com/nichochar/cc-connect)**, or **[opencode-telegram](https://github.com/grinev/opencode-telegram-bot)** | Chat bridge (Discord, multi-platform, or Telegram) | `--no-chat` |
| **SessionStart hook** | Syncs Data Machine agents into CLAUDE.md on every session (Claude Code and Studio Code) | Always installed |
| **[WordPress agent skills](https://github.com/WordPress/agent-skills)** | WP development patterns (cloned at install) | `--no-skills` |

## VPS vs. Local

| | VPS | Local |
|---|---|---|
| **Always-on** | Runs 24/7 via systemd | Runs while your machine is awake |
| **Scheduled flows** | Cron-driven briefings, digests | No overnight automation |
| **Infrastructure** | apt, nginx, SSL, systemd | None — uses your existing WordPress |
| **Root required** | Yes (default) | No |
| **Best for** | Production agents, fleet members | Development, personal use, testing |

Both modes use the same Data Machine agent engine, same abilities, same memory system. The difference is just infrastructure.

## Memory System

Data Machine manages memory files across three layers, each scoped to a different owner:

### Shared Layer (all agents)

| File | Purpose |
|------|---------|
| **SITE.md** | Auto-generated site context — WordPress config, active plugins, post counts. Read-only. |
| **RULES.md** | Behavioral constraints for every agent. Admin-editable. |

### Agent Layer (per agent)

| File | Purpose |
|------|---------|
| **SOUL.md** | Identity — name, voice, rules. Rarely changes. |
| **MEMORY.md** | Knowledge — project state, lessons learned. Grows over time. |

### User Layer (per human)

| File | Purpose |
|------|---------|
| **USER.md** | Information about the human the agent works with. Injected in chat and editor contexts only. |

On activation, Data Machine creates a default agent for the first admin user and scaffolds all three layers. Each additional agent gets its own SOUL.md and MEMORY.md when created, sharing the same SITE.md and USER.md. All discovered files are injected into every session via the runtime's config — `opencode.json` (`{file:}` includes) for OpenCode, `CLAUDE.md` (`@` includes) for Claude Code and Studio Code. The agent doesn't manage memory infrastructure — it just reads and writes these files. DM handles the rest.

**Runtime sync (Claude Code / Studio Code):** A SessionStart hook queries Data Machine on every session start and updates the `@` includes in CLAUDE.md. New agents created after setup are automatically discovered — no manual config regeneration needed. Claude Code's built-in auto-memory is disabled, since DM handles memory. Studio Code uses the same hook mechanism — it runs the Claude Agent SDK with the `claude_code` preset, which loads `.claude/settings.json` hooks by default.

## Abilities

Data Machine exposes all agent functionality through WordPress core's [Abilities API](https://developer.wordpress.org/reference/functions/wp_register_ability/) (`wp_register_ability`). Every tool an agent can use is a native WordPress primitive — discoverable, permissioned, and executable via REST, CLI, or chat. No proprietary abstraction layer.

## What Data Machine Gives You

Data Machine is the substrate wp-coding-agents composes on top of — memory, scheduling, workspace, abilities. It is not optional. Installing wp-coding-agents means installing DM. Uninstall the plugin after the fact if you change your mind.

- Persistent memory across sessions (SOUL.md, USER.md, MEMORY.md)
- Self-scheduling via flows and cron
- Task queues for multi-phase projects
- Agent Ping webhooks for fleet coordination
- AI tools (content generation, publishing, search)
- Managed workspace for git repos (`/var/lib/datamachine/workspace/`) with **per-branch worktrees** so multiple parallel agent sessions can edit different branches of the same repo without stepping on each other (`workspace worktree add <repo> <branch>` → operate on the `<repo>@<branch-slug>` handle)
- GitHub integration (issues, PRs, repos)
- Policy-controlled git operations (add, commit, push with allowlists; primary checkout is read-only by default)

## Why Root? (VPS only)

wp-coding-agents defaults to running the agent as `root` on VPS installs. On a single-purpose agent VPS, root keeps things simple:

- **Package management works.** Tools like Kimaki self-upgrade via `npm i -g`, which writes to `/usr/lib/node_modules/`. A non-root user can't do this without sudo configuration, so upgrades fail silently or require manual intervention.
- **No permission drift.** Files created by different processes (npm, systemd, git) all share the same owner. No chown chasing.
- **These are dedicated agent servers.** Even when multiple agents share a VPS, they share the same toolchain (Node.js, npm, runtime). User separation between agents doesn't add meaningful security — they already share the filesystem, database server, and package tree. Isolation happens at the WordPress and Data Machine layer (scoped agent files, permissions, memory), not at the OS user level.

If you have compliance requirements for OS-level user separation, use `--non-root` to create a dedicated service user. Just know you'll need to handle permission issues for global package operations (e.g., add sudoers rules for npm).

Local installs run as your current user — no root, no service user, no chown.

## Chat Bridge Configuration

### Kimaki (Discord)

The default chat bridge for OpenCode. On VPS, wp-coding-agents installs post-upgrade hooks that:

- **Remove unwanted bundled skills** — Kimaki ships with skills for frameworks and tools that aren't relevant to WordPress agent workflows. The kill list (`kimaki/skills-kill-list.txt`) controls which skills are removed after each upgrade.
- **Filter redundant context** — When Data Machine is installed, a plugin strips Kimaki's built-in memory injection and scheduling instructions from the agent context, since DM handles those concerns. Saves ~2,400 tokens per session.

To customize the kill list, edit `kimaki/skills-kill-list.txt` before running setup, or edit `/opt/kimaki-config/skills-kill-list.txt` on the server after install.

On local installs, Kimaki installs globally via npm but without a systemd service. Run it manually:

```bash
cd /path/to/wordpress && kimaki
```

### cc-connect

The default chat bridge for Claude Code. Supports multiple chat platforms. Generates a `config.toml` pointing at the WordPress site root and installs as a launchd (macOS) or systemd (VPS) service.

```bash
cd /path/to/wordpress && cc-connect  # manual start
```

### Telegram

Use `--chat telegram` to install [opencode-telegram](https://github.com/grinev/opencode-telegram-bot). This sets up two services: `opencode-serve` (the OpenCode HTTP server) and `opencode-telegram` (the bot that connects to it). Works on VPS and macOS (launchd).

Required environment variables:

| Variable | Description |
|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_ALLOWED_USER_ID` | Your numeric Telegram user ID (get from [@userinfobot](https://t.me/userinfobot)) |

Optional:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_MODEL_PROVIDER` | `opencode` | Model provider for the bot |
| `OPENCODE_MODEL_ID` | `big-pickle` | Model ID for the bot |

Credentials are stored in `~/.config/opencode-telegram-bot/.env` (chmod 600). You can set them as environment variables during setup or edit the file after install.

## Requirements

**VPS:**
- Linux server (Ubuntu/Debian)
- Node.js 18+
- PHP 8.0+
- MySQL/MariaDB
- nginx

**Local:**
- macOS or Linux desktop
- An existing WordPress install (WordPress Studio, MAMP, manual, etc.)
- Node.js 18+
- WP-CLI

## Related Projects

- **[wp-openclaw](https://github.com/Sarai-Chinwag/wp-openclaw)** — Same concept, uses [OpenClaw](https://github.com/openclaw/openclaw) as an all-in-one agent runtime. OpenClaw manages its own memory, skills, and channels. Better for standalone autonomous agents that need to self-manage everything. wp-coding-agents is the composable alternative — separate tools, each doing one thing.
- **[Data Machine](https://github.com/Extra-Chill/data-machine)** — The memory and scheduling layer. Works with any AI agent framework.
- **[Data Machine Code](https://github.com/Extra-Chill/data-machine-code)** — Developer tools extension for Data Machine. Workspace management, GitHub integration, git operations.

## Contributing

Issues + PRs welcome.

## License

MIT — see [LICENSE](LICENSE)

---

*Built by [Extra Chill](https://extrachill.com)*
