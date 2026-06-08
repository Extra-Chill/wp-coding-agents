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

On activation, Data Machine creates a default agent and scaffolds its memory files. Additional agents get their own files when created. The runtime loads the selected agent's registered files for each session — the agent wakes up knowing who it is and what it's been working on. No memory management overhead in the context window.

## Runtime Auto-Discovery

Drop a file in `runtimes/`, it's available. The script scans `runtimes/*.sh` for available runtimes and auto-detects which one to use based on what's installed:

```
hooks/
└── dm-agent-sync.sh   # SessionStart hook: refresh CLAUDE.md memory includes
runtimes/
├── opencode.sh        # OpenCode: opencode.json instructions + AGENTS.md
├── claude-code.sh     # Claude Code: CLAUDE.md + @ includes + .mcp.json
└── studio-code.sh     # Studio Code: CLAUDE.md + @ includes + Studio tools
```

Each runtime implements the same interface — install, config generation, MCP merge, skills directory. Adding a new runtime means implementing those functions in a single file.

## Standalone or Orchestrated

wp-coding-agents works in two modes with the same setup:

**Standalone** — Data Machine handles autonomy. The agent self-schedules flows, queues tasks, runs on cron. No orchestrator needed.

**Orchestrated** — Optional tools can route work to the agent without becoming universal requirements. Homeboy is the optional repo-aware coding-task orchestrator when installed with `--with-homeboy`; chat bridges such as Kimaki, cc-connect, and Telegram are communication paths for the selected install.

```
 Optional orchestrator / chat bridge
   ├── Homeboy agent-task ──▶  repo-aware Codebox task
   ├── CLI dispatch ───────▶  selected chat bridge
   └── direct session ─────▶  agent @ WordPress site
```

Installs without Homeboy still use Data Machine workspaces, flows, jobs, and bridge dispatch. Installs without Kimaki use the selected bridge or terminal runtime; Kimaki-specific routing only applies when Kimaki is selected.

Homeboy setup verification normally proves Homeboy is installed, linked, and advertised through `datamachine_code_homeboy_available`. To prove the full Codebox fleet-cooking path, run the explicit opt-in `scripts/verify-homeboy-codebox-canary.sh` helper from the verification skill. It can call a model, so it requires provider secret environment variable names and validates only read-only status/log/artifact evidence.

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

On macOS, `--local` is auto-detected. The script installs Data Machine, the coding agent runtime, the upgrade skill, and optionally a chat bridge — no infrastructure, no root, no systemd.

Start your agent:

```bash
cd ~/Studio/my-wordpress-website && opencode      # OpenCode terminal
cd ~/Studio/my-wordpress-website && claude         # Claude Code terminal
cd ~/Studio/my-wordpress-website && studio code    # Studio Code terminal
cd ~/Studio/my-wordpress-website && kimaki         # OpenCode + Discord
```

### VPS

#### Let Your Agent Do It

Use the one-shot setup guide with your local coding agent (Claude Code, Cursor, etc.):

```
operator-entrypoints/wp-coding-agents-setup/setup.md
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
| `--with-homeboy` | Enable optional [Homeboy](https://github.com/Extra-Chill/homeboy) project setup for repo-aware developer workflows |
| `--no-chat` | Skip chat bridge |
| `--chat <bridge>` | Chat bridge: `kimaki` (Discord, default for OpenCode), `cc-connect` (default for Claude Code and Studio Code), `telegram` |
| `--multisite` | Convert to WordPress Multisite (subdirectory by default) |
| `--subdomain` | Subdomain multisite (use with `--multisite`, requires wildcard DNS) |
| `--no-skills` | Skip installing the wp-coding-agents upgrade skill |
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

# Local: recommended developer power layer with Homeboy project setup
EXISTING_WP=~/Studio/my-site ./setup.sh --local --with-homeboy

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
| **AI Provider for Claude Code** | wp-coding-agents-carried WP AI Client provider backed by Claude Code OAuth credentials | Installed when Claude Code is selected or detected |
| **[Homeboy](https://github.com/Extra-Chill/homeboy)** | Optional developer power layer for project status, component-aware checks, review loops, and WordPress extension verification | `--with-homeboy` |
| **[Kimaki](https://kimaki.xyz)**, **[cc-connect](https://github.com/nichochar/cc-connect)**, or **[opencode-telegram](https://github.com/grinev/opencode-telegram-bot)** | Chat bridge (Discord, multi-platform, or Telegram) | `--no-chat` |
| **SessionStart hook** | Syncs Data Machine agents into CLAUDE.md on every session (Claude Code and Studio Code) | Always installed |
| **wp-coding-agents upgrade skill** | Ongoing upgrade runbook installed with the target agent. The setup skill is intentionally not installed; it is a single-use pre-install entrypoint kept in this repo for the operator's local agent. | `--no-skills` |

## VPS vs. Local

| | VPS | Local |
|---|---|---|
| **Always-on** | Runs 24/7 via systemd | Runs while your machine is awake |
| **Scheduled flows** | Cron-driven briefings, digests | No overnight automation |
| **Infrastructure** | apt, nginx, SSL, systemd | None — uses your existing WordPress |
| **Root required** | Yes (default) | No |
| **Best for** | Production agents, always-on automation | Development, personal use, testing |

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

On activation, Data Machine creates a default agent for the first admin user and scaffolds all three layers. Each additional agent gets its own SOUL.md and MEMORY.md when created, sharing the same SITE.md and USER.md. The selected agent's discovered files are injected into each session via the runtime's config — top-level `opencode.json` `instructions` for OpenCode, `CLAUDE.md` (`@` includes) for Claude Code and Studio Code. The agent doesn't manage memory infrastructure — it just reads and writes these files. DM handles the rest.

**Runtime sync:** Claude Code and Studio Code use a SessionStart hook that queries Data Machine on every session start and updates the `@` includes in CLAUDE.md. OpenCode uses top-level `instructions` plus a Kimaki plugin that only recomposes Data Machine memory files before OpenCode reads them; it does not write `agent.build.prompt`, `agent.plan.prompt`, or register every Data Machine agent into OpenCode config. Claude Code's built-in auto-memory is disabled, since DM handles memory. Studio Code uses the same hook mechanism — it runs the Claude Agent SDK with the `claude_code` preset, which loads `.claude/settings.json` hooks by default.

## Abilities

Data Machine exposes all agent functionality through WordPress core's [Abilities API](https://developer.wordpress.org/reference/functions/wp_register_ability/) (`wp_register_ability`). Every tool an agent can use is a native WordPress primitive — discoverable, permissioned, and executable via REST, CLI, or chat. No proprietary abstraction layer.

## What Data Machine Gives You

Data Machine is the substrate wp-coding-agents composes on top of — memory, scheduling, workspace, abilities. It is not optional. Installing wp-coding-agents means installing DM. Uninstall the plugin after the fact if you change your mind.

- Persistent memory across sessions (SOUL.md, USER.md, MEMORY.md)
- Self-scheduling via flows and cron
- Task queues for multi-phase projects
- Agent Ping webhooks and CLI bridge dispatch for cross-agent coordination
- AI tools (content generation, publishing, search)
- Managed workspace for git repos (`/var/lib/datamachine/workspace/`) with **per-branch worktrees** so multiple parallel agent sessions can edit different branches of the same repo without stepping on each other (`workspace worktree add <repo> <branch>` → operate on the `<repo>@<branch-slug>` handle)
- GitHub integration (issues, PRs, repos)
- Policy-controlled git operations (add, commit, push with allowlists; primary checkout is read-only by default)

## Optional Homeboy Layer

### Claude Code Provider

When the selected or detected runtime includes Claude Code, wp-coding-agents syncs and activates a carried plugin at:

```
wp-content/plugins/ai-provider-for-claude-code
```

This plugin registers WP AI Client provider id `claude-code`. It is backed by Claude Code OAuth credentials and sends Anthropic Messages API requests with Claude Code subscription headers. It is not an official Anthropic API-key provider and does not require WP AI Gateway for Homeboy Codebox cooking.

Use WP AI Gateway only when an external client needs an OpenAI-compatible WordPress endpoint. Homeboy Codebox tasks can select the provider directly with `--provider claude-code` and pass the carried provider plugin path through the provider config.

Configuration:

- `AI_PROVIDER_CLAUDE_CODE_REFRESH_TOKEN` provides the Claude Code OAuth refresh token.
- `AI_PROVIDER_CLAUDE_CODE_ACCESS_TOKEN` and `AI_PROVIDER_CLAUDE_CODE_EXPIRES_AT` optionally provide a cached access token.
- The same names may be supplied as WordPress constants.
- `ai_provider_claude_code_oauth_tokens` can filter token data at runtime.

`--with-homeboy` adds Homeboy as an optional, recommended developer power layer. Homeboy is not bundled or vendorized by wp-coding-agents; setup verifies or installs the external Homeboy CLI, verifies the WordPress extension, then exposes its availability to Data Machine Code so composed agent instructions can include Homeboy workflows.

When Homeboy is available, the composed `AGENTS.md` Homeboy Codebox section is the canonical guidance for repo-aware coding fan-out: use `homeboy agent-task` plans/runs with WP Codebox sandboxes for isolated tasks. Without Homeboy, agents should continue using Data Machine Code worktrees, normal git review, and the selected chat or terminal runtime; do not assume Homeboy commands exist.

The setup model is intentionally specific:

```text
WordPress site root
  = Homeboy project

DMC workspace primary checkouts
  = Homeboy components attached to that project

DMC worktrees (`repo@branch`)
  = task-specific ephemeral worktrees skipped by default
```

The site root is a Homeboy project, not a component, so setup does not create `homeboy.json` in the WordPress root. Primary Data Machine Code workspace checkouts that already contain `homeboy.json` can be attached as project components. Per-branch `@` worktrees are skipped by default because they are temporary task checkouts derived from the primary component repos.

When enabled, setup should leave you with:

- A Homeboy project for the WordPress site, derived from the site ID, domain, and base path
- Attached Homeboy components for eligible DMC workspace primary checkouts
- WordPress Homeboy extension installed and verified
- Data Machine Code's `datamachine_code_homeboy_available` option synced with CLI availability
- `AGENTS.md` recomposed so the conditional Homeboy guidance appears for coding agents

Verification commands:

```bash
homeboy --version
homeboy extension list
homeboy project show <project-id>
homeboy project components list <project-id>
wp option get datamachine_code_homeboy_available --path=/path/to/wordpress
wp datamachine memory compose AGENTS.md --path=/path/to/wordpress
```

For WordPress Studio installs, use Studio's WP-CLI wrapper for the WordPress commands:

```bash
studio wp option get datamachine_code_homeboy_available
studio wp datamachine memory compose AGENTS.md
```

## Why Root? (VPS only)

wp-coding-agents defaults to running the agent as `root` on VPS installs. On a single-purpose agent VPS, root keeps things simple:

- **Package management works.** Tools like Kimaki self-upgrade via `npm i -g`, which writes to `/usr/lib/node_modules/`. A non-root user can't do this without sudo configuration, so upgrades fail silently or require manual intervention.
- **No permission drift.** Files created by different processes (npm, systemd, git) all share the same owner. No chown chasing.
- **These are dedicated agent servers.** Even when multiple agents share a VPS, they share the same toolchain (Node.js, npm, runtime). User separation between agents doesn't add meaningful security — they already share the filesystem, database server, and package tree. Isolation happens at the WordPress and Data Machine layer (scoped agent files, permissions, memory), not at the OS user level.

If you have compliance requirements for OS-level user separation, use `--non-root` to create a dedicated service user. Just know you'll need to handle permission issues for global package operations (e.g., add sudoers rules for npm).

Local installs run as your current user — no root, no service user, no chown.

## Chat Bridge Configuration

### Kimaki (Discord)

The default chat bridge for OpenCode. On VPS and macOS launchd installs, wp-coding-agents starts Kimaki with native 0.13 skill filters and installs post-upgrade hooks that:

- **Allow only managed bundled skills** — Kimaki ships with skills for frameworks and tools that aren't relevant to WordPress agent workflows. The allowlist (`bridges/kimaki/skills-enable-list.txt`) is rendered as `--enable-skill` startup flags, so future Kimaki skills stay hidden by default and package-managed skill directories are left intact.
- **Filter redundant context** — A plugin strips Kimaki's built-in memory injection and scheduling instructions from the agent context, since DM handles those concerns. Saves ~2,400 tokens per session.
- **Use native cwd routing for DMC worktrees** — When Data Machine Code creates or reuses an existing checkout, launch the Discord helper thread with `kimaki send --cwd <workspace-path> ...`. Kimaki records the thread/worktree metadata itself; wp-coding-agents does not write Kimaki's SQLite database.

To customize the managed skill filters, edit `bridges/kimaki/skills-enable-list.txt` before running setup, or edit `/opt/kimaki-config/skills-enable-list.txt` on a VPS or `$KIMAKI_DATA_DIR/kimaki-config/skills-enable-list.txt` on a local install after setup.

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

## Outbound Dispatch (`agents/dispatch-message`)

Each chat bridge installed by wp-coding-agents registers itself as a **CLI channel** with the Data Machine Code generic CLI transport runtime (Extra-Chill/data-machine-code#412). That runtime backs the `agents/dispatch-message` ability, so Data Machine flows can push messages out to whatever platform your bridge speaks — without bespoke webhooks, without HTTP detours, without per-bridge plumbing in DMC itself.

### How it wires up

On install (and every `upgrade.sh` run), each bridge writes its channel config into a mu-plugin file at:

```
$WP_PATH/wp-content/mu-plugins/wp-coding-agents-channels.php
```

The file is owned end-to-end by bridge installers: it is created on first registration, each bridge contributes a marker-delimited block (`// BEGIN bridge:<name>` … `// END bridge:<name>`), and the same install path can rewrite or remove its block idempotently. The file registers entries via the `datamachine_code_cli_channels` filter:

```php
$channels['kimaki'] = [
    'command' => '/usr/local/bin/kimaki',
    'args'    => [ 'send', '--channel', '{recipient}', '--prompt', '{message}' ],
    'detach'  => true,
    'timeout' => 600,
];
```

At dispatch time the runtime substitutes `{recipient}` and `{message}` and shells the configured command. No HTTP hop, no nginx detour, no Python.

### Channel names + recipient semantics

| Bridge          | Channel name | `recipient` is…                              | `message` is…                |
|-----------------|--------------|----------------------------------------------|------------------------------|
| `bridges/kimaki.sh`     | `kimaki`     | Discord channel ID (numeric string)          | Prompt body delivered to the agent in that channel |
| `bridges/cc-connect.sh` | `cc-connect` | cc-connect project name (from `config.toml`) | Message body sent via `cc-connect send` |
| `bridges/telegram.sh`   | `telegram`   | Telegram chat ID (numeric, user or group)    | Message body posted via Telegram's `sendMessage` Bot API |

A flow step calling the ability looks like:

```
agents/dispatch-message
  channel:   'kimaki'
  recipient: '1476075959806590989'
  message:   'Time for your check-in.'
```

### Bridge-specific notes

- **kimaki** registers the native `kimaki` binary. Kimaki 0.13 validates requested session agents and falls back to the default/build agent when the requested agent is unavailable, so wp-coding-agents does not rewrite `--agent` arguments.
- **cc-connect** assumes `cc-connect send` accepts `--project <name> <message>`. cc-connect routes outgoing messages through its currently-bound platform per project (Feishu/DingTalk/Slack/Telegram/Discord/etc.), so `recipient` is the cc-connect project, not a raw chat ID. **Assumption to validate against upstream:** if `--project` is unsupported, the argv collapses to `["send","{message}"]` and `recipient` becomes informational only. Tracked alongside Extra-Chill/wp-coding-agents#129.
- **telegram** is the odd one out. `opencode-telegram-bot` is inbound-only (polls Telegram, forwards to a local opencode server); it has no outbound `send` subcommand. To preserve the channel/recipient model, the bridge registers `curl` against Telegram's `sendMessage` Bot API with `TELEGRAM_BOT_TOKEN` baked in. `recipient` is a Telegram chat ID. The token is captured at install/upgrade time from the existing bot `.env` if not in the current shell — rotating the token requires re-running `upgrade.sh` so the channel config picks up the new value.

### Migrating from the legacy `agent-ping` webhook

Earlier wp-coding-agents installs on Extra Chill's VPS shipped an out-of-band Python webhook at `/opt/agent-ping-webhook/` that POSTed to a local HTTP listener and shelled `kimaki send`. Once the CLI-channel runtime (Extra-Chill/data-machine-code#412) and these bridge registrations are deployed, that stack is dead weight — the same dispatch goes through `agents/dispatch-message` with no HTTP hop.

Retirement is a one-time manual cleanup. There is no helper script: this stack only exists on one host, and shipping permanent automation for a one-shot deletion would be technical debt for an experimental feature. On a host that has the legacy stack:

1. **Reconfigure the dispatch flow first.** Edit the data-machine flow that was POSTing to `https://<site>/agent-ping/` to instead invoke `agents/dispatch-message` with `channel='kimaki'` and `recipient='<discord-channel-id>'`. Run it manually (`wp datamachine flow run <id>`) and confirm the message lands.
2. **Disable and remove the systemd unit.**
   ```bash
   sudo systemctl disable --now agent-ping-webhook.service
   sudo rm /etc/systemd/system/agent-ping-webhook.service
   sudo systemctl daemon-reload
   ```
3. **Remove the webhook directory.**
   ```bash
   sudo rm -rf /opt/agent-ping-webhook/
   ```
4. **Drop the `location /agent-ping/` block from your nginx site config** (e.g. `/etc/nginx/sites-available/<site>`), then:
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   ```
5. **Free the local port (8422 in the EC setup) and remove the token file.**
   ```bash
   sudo rm -f /home/opencode/.secrets/agent-ping-token.txt
   ```

After this, the only outbound message path is `agents/dispatch-message` → DMC CLI runtime → bridge CLI. If you weren't running the legacy webhook to begin with (every install of wp-coding-agents from v0.5.x onward), skip the migration entirely — the bridge registrations land on a clean disk.

## Worktree Session Attribution (Runtime Signatures)

When a coding-agent session asks Data Machine Code to create a worktree, DMC captures **origin-session metadata** so the worktree carries a breadcrumb back to the runtime that spawned it. DMC reads that metadata from environment variables the runtime sets on the worktree-creating process.

The env-var names are vendor-specific (`OPENCODE_RUN_ID`, etc.) so DMC cannot enumerate them without knowing about opencode or any other runtime — a layer-purity violation per the platform's coding rules. The fix (Extra-Chill/data-machine-code#416) moves the env-var → field map out of DMC into a filter:

```php
apply_filters( 'datamachine_code_worktree_runtime_signatures', [] );
```

wp-coding-agents is the integration layer that knows about kimaki and opencode — it installs both, writes the systemd units that pass those env vars into the spawned processes, and is the only honest place those brand names live. So **wp-coding-agents owns the registration.**

### How it wires up

On install (and every `upgrade.sh` run), each runtime/bridge writes its signature into a mu-plugin file at:

```
$WP_PATH/wp-content/mu-plugins/wp-coding-agents-runtimes.php
```

The file is owned end-to-end by wp-coding-agents installers: created on first registration, each runtime contributes a marker-delimited block (`// BEGIN runtime:<id>` … `// END runtime:<id>`), and the same install path can rewrite or remove its block idempotently. The file registers entries via the filter:

```php
$signatures['opencode'] = [
    'run_id' => 'OPENCODE_RUN_ID',
];
```

DMC reads the map, walks each runtime's subkeys, and sniffs the named env vars at worktree-create time. The subkey set is open — DMC does not validate against a closed schema. Conventional subkeys are `session_id`, `thread_id`, `thread_url`, `run_id`; integrations may add more.

Kimaki 0.13 does not currently export stable session/thread attribution env vars such as `KIMAKI_SESSION_ID`, `KIMAKI_THREAD_ID`, or `KIMAKI_THREAD_URL` to OpenCode/tool subprocesses. OpenCode source and a live Kimaki/OpenCode runtime smoke show `OPENCODE_RUN_ID`, but not `OPENCODE_SESSION_ID`. Rich Discord thread attribution is tracked upstream in https://github.com/remorses/kimaki/issues/137; until Kimaki ships a documented contract, wp-coding-agents registers only the env vars that actually exist.

### Registered signatures

| Runtime ID  | Subkey       | Env var                | What it identifies                                  |
|-------------|--------------|------------------------|-----------------------------------------------------|
| `opencode`  | `run_id`     | `OPENCODE_RUN_ID`      | Specific OpenCode run in the current process tree   |

Adding a new runtime is a one-liner: register a new block in the relevant `runtimes/<name>.sh` or `bridges/<name>.sh` via `runtime_signature_register <runtime_id> <signature_json>` (see `lib/runtime-signature.sh`).

### Layer purity

**The brand names live here on purpose.** wp-coding-agents is the integration plugin and the only place in the stack that should know about specific coding-agent runtimes. If you ever see DMC ship code that names `kimaki`, `opencode`, `KIMAKI_*`, or `OPENCODE_*` directly, **that is a layer-purity violation and should be filed against DMC, not patched here.** DMC must stay runtime-agnostic; vendor naming is wp-coding-agents' job.

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
