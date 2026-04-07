# WP-OpenCode

**A lean, composable AI agent on WordPress.**

wp-opencode puts an AI agent on a VPS with WordPress as its operating layer. Each component does one thing: [OpenCode](https://opencode.ai) handles code, [Data Machine](https://github.com/Extra-Chill/data-machine) handles memory and scheduling, and a pluggable chat bridge ([Kimaki](https://kimaki.xyz) for Discord, [opencode-telegram](https://github.com/grinev/opencode-telegram-bot) for Telegram, or none) handles communication. The agent's context window stays clean — no overhead for systems it's not using.

## How It Works

```
 You (Discord / Telegram / SSH)
   │
   ▼
 Chat bridge (Kimaki, Telegram, or direct)
   │
   ▼
 OpenCode (coding agent)
   │
   ├── AGENTS.md ─── workspace conventions
   ├── SOUL.md ───── identity (who am I?)
   ├── USER.md ───── human profile (who am I helping?)
   ├── MEMORY.md ─── accumulated knowledge
   │
   ├── WP-CLI ────── WordPress control
   └── Data Machine ─ self-scheduling + AI tools
```

Data Machine creates three memory files on activation. They're injected into every session — the agent wakes up knowing who it is, who you are, and what it's been working on. No memory management overhead in the context window.

## Standalone or Fleet

wp-opencode works in two modes with the same setup:

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

### Let Your Agent Do It

Add the `wp-opencode-setup` skill to your local coding agent (Claude Code, Cursor, etc.):

```
skills/wp-opencode-setup/
```

Then: "Help me set up wp-opencode on my VPS"

Your local agent SSHs into the server, runs the setup, and your VPS agent wakes up.

### Manual

```bash
ssh root@your-server-ip
git clone https://github.com/Extra-Chill/wp-opencode.git
cd wp-opencode
SITE_DOMAIN=yourdomain.com ./setup.sh
systemctl start kimaki  # or: systemctl start opencode-serve opencode-telegram
```

## Setup Options

| Flag | Description |
|------|-------------|
| `--existing` | Add to existing WordPress (skip WP install) |
| `--no-data-machine` | Skip Data Machine (no persistent memory/scheduling) |
| `--no-chat` | Skip chat bridge |
| `--chat <bridge>` | Chat bridge to install: `kimaki` (Discord, default) or `telegram` |
| `--multisite` | Convert to WordPress Multisite (subdirectory by default) |
| `--subdomain` | Subdomain multisite (use with `--multisite`, requires wildcard DNS) |
| `--no-skills` | Skip WordPress agent skills |
| `--skip-deps` | Skip apt packages |
| `--skip-ssl` | Skip SSL/HTTPS |
| `--root` | Run agent as root (default) |
| `--non-root` | Run agent as dedicated service user (`opencode`) |
| `--dry-run` | Print commands without executing |

### Examples

```bash
# Full setup: WordPress + DM + Discord
SITE_DOMAIN=example.com ./setup.sh

# Telegram instead of Discord
SITE_DOMAIN=example.com TELEGRAM_BOT_TOKEN=xxx TELEGRAM_ALLOWED_USER_ID=123 ./setup.sh --chat telegram

# No chat bridge (SSH-only access)
SITE_DOMAIN=example.com ./setup.sh --no-chat

# Existing WordPress site
EXISTING_WP=/var/www/mysite ./setup.sh --existing

# Multisite network (subdomain)
SITE_DOMAIN=example.com ./setup.sh --multisite --subdomain

# Dry run
SITE_DOMAIN=example.com ./setup.sh --dry-run
```

## What Gets Installed

| Component | Role | Optional? |
|-----------|------|-----------|
| **WordPress** | Site platform, WP-CLI access | No |
| **[OpenCode](https://opencode.ai)** | AI coding agent runtime | No |
| **[Data Machine](https://github.com/Extra-Chill/data-machine)** | Memory (SOUL/USER/MEMORY.md), self-scheduling, AI tools, Agent Ping | `--no-data-machine` |
| **[Kimaki](https://kimaki.xyz)** or **[opencode-telegram](https://github.com/grinev/opencode-telegram-bot)** | Chat bridge (Discord or Telegram) | `--no-chat` |
| **[WordPress agent skills](https://github.com/WordPress/agent-skills)** | WP development patterns (cloned at install) | `--no-skills` |

## Memory System

Data Machine manages three files that define the agent:

| File | Priority | Purpose |
|------|----------|---------|
| **SOUL.md** | 10 | Identity — name, voice, rules |
| **USER.md** | 20 | Human profile — who you are, preferences |
| **MEMORY.md** | 30 | Knowledge — project state, lessons learned |

These are injected into every session via `opencode.json`. The agent doesn't manage memory infrastructure — it just reads and writes these files. DM handles the rest.

## Abilities

Data Machine exposes all agent functionality through WordPress core's [Abilities API](https://developer.wordpress.org/reference/functions/wp_register_ability/) (`wp_register_ability`). Every tool an agent can use is a native WordPress primitive — discoverable, permissioned, and executable via REST, CLI, or chat. No proprietary abstraction layer.

## With or Without Data Machine

**With DM (default):**
- Persistent memory across sessions (SOUL.md, USER.md, MEMORY.md)
- Self-scheduling via flows and cron
- Task queues for multi-phase projects
- Agent Ping webhooks for fleet coordination
- AI tools (content generation, publishing, search)

**Without DM (`--no-data-machine`):**
- Agent responds when prompted, no autonomous operation
- No persistent memory between sessions
- No self-scheduling
- Good for development-only setups where you just need a coding assistant

## Why Root?

wp-opencode defaults to running the agent as `root`. On a single-purpose agent VPS, root keeps things simple:

- **Package management works.** Tools like Kimaki self-upgrade via `npm i -g`, which writes to `/usr/lib/node_modules/`. A non-root user can't do this without sudo configuration, so upgrades fail silently or require manual intervention.
- **No permission drift.** Files created by different processes (npm, systemd, git) all share the same owner. No chown chasing.
- **These are dedicated agent servers.** Even when multiple agents share a VPS, they share the same toolchain (Node.js, npm, OpenCode). User separation between agents doesn't add meaningful security — they already share the filesystem, database server, and package tree. Isolation happens at the WordPress and Data Machine layer (scoped agent files, permissions, memory), not at the OS user level.

If you have compliance requirements for OS-level user separation, use `--non-root` to create a dedicated `opencode` service user. Just know you'll need to handle permission issues for global package operations (e.g., add sudoers rules for npm).

## Chat Bridge Configuration

### Kimaki (Discord)

The default chat bridge. wp-opencode installs post-upgrade hooks that:

- **Remove unwanted bundled skills** — Kimaki ships with skills for frameworks and tools that aren't relevant to WordPress agent workflows. The kill list (`kimaki/skills-kill-list.txt`) controls which skills are removed after each upgrade.
- **Filter redundant context** — When Data Machine is installed, a plugin strips Kimaki's built-in memory injection and scheduling instructions from the agent context, since DM handles those concerns. Saves ~2,400 tokens per session.

To customize the kill list, edit `kimaki/skills-kill-list.txt` before running setup, or edit `/opt/kimaki-config/skills-kill-list.txt` on the server after install.

### Telegram

Use `--chat telegram` to install [opencode-telegram](https://github.com/grinev/opencode-telegram-bot) instead. This sets up two systemd services: `opencode-serve` (the OpenCode HTTP server) and `opencode-telegram` (the bot that connects to it).

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

- Linux server (Ubuntu/Debian)
- Node.js 18+
- PHP 8.0+
- MySQL/MariaDB
- nginx

## Related Projects

- **[wp-openclaw](https://github.com/Sarai-Chinwag/wp-openclaw)** — Same concept, uses [OpenClaw](https://github.com/openclaw/openclaw) as an all-in-one agent runtime. OpenClaw manages its own memory, skills, and channels. Better for standalone autonomous agents that need to self-manage everything. wp-opencode is the composable alternative — separate tools, each doing one thing.
- **[Data Machine](https://github.com/Extra-Chill/data-machine)** — The memory and scheduling layer. Works with any AI agent framework, not just OpenCode.

## Contributing

Issues + PRs welcome.

## License

MIT — see [LICENSE](LICENSE)

---

*Built by [Extra Chill](https://extrachill.com)*
