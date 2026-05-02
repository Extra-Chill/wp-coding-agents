---
name: wp-coding-agents-setup
description: "Install wp-coding-agents on a VPS or local machine. Use this skill from your LOCAL machine to deploy a self-contained WordPress + coding agent environment on a remote server, or to set up a local agent on your own machine."
compatibility: "For VPS: requires SSH access, Ubuntu/Debian recommended. For local: requires an existing WordPress install (WordPress Studio, MAMP, manual, etc.) and Node.js."
---

# WP Coding Agents Setup Skill

**Purpose:** Help a user install wp-coding-agents on a remote VPS or their local machine.

This skill is for the **local agent** (Claude Code, Cursor, etc.) assisting with installation. Once the coding agent is running on the VPS with a chat bridge (e.g., Kimaki for Discord, cc-connect, Telegram bot), this skill is no longer needed — the VPS agent takes over. For local installs, the agent runs directly on the user's machine.

---

## FIRST: Interview the User

**Do NOT proceed with installation until you've asked these questions and gotten answers.**

### Question 1: Installation Type

> "Are you setting up a **fresh WordPress site on a VPS**, do you have an **existing WordPress site**, or do you want to run **locally on your own machine**?"

**Options:**
- **Fresh VPS install** — New VPS, new WordPress site
- **Existing WordPress (VPS)** — Site already running on a server, just add a coding agent
- **Local install** — Use an existing WordPress on your own machine (WordPress Studio, MAMP, etc.)
- **Migration** — Site exists elsewhere, moving to this VPS

### Question 2: Coding Agent Runtime

> "Which coding agent(s) do you want to use? You can choose one or more (comma-separated).
>
> - **OpenCode** — Open-source, supports zen free models, uses opencode.json config
> - **Claude Code** — Anthropic's CLI agent, uses CLAUDE.md config with @ includes
> - **Studio Code** — WordPress Studio's built-in AI agent, uses CLAUDE.md + Studio tools
>
> If multiple are installed, the script auto-detects. You can also specify with `--runtime` (e.g., `--runtime claude-code,studio-code`)."

### Question 3: Chat Bridge

> "How do you want to communicate with your agent?
>
> - **Discord (via Kimaki)** — Default for OpenCode. Your agent gets a Discord bot.
> - **cc-connect** — Default for Claude Code. Multi-platform chat bridge.
> - **Telegram** — Your agent gets a Telegram bot (via @grinev/opencode-telegram-bot). OpenCode only.
> - **No chat bridge** — Run the agent manually via SSH or terminal when needed."

### Question 4: Homeboy Developer Layer

> "Do you want the optional **Homeboy developer layer** enabled with `--with-homeboy`?
>
> - Recommended for developers who want repo-aware checks, project status, review loops, and WordPress extension verification.
> - Homeboy is an external CLI; wp-coding-agents does not bundle or vendor it.
> - Setup treats the WordPress site root as the Homeboy **project**, not a component.
> - Data Machine Code primary workspace checkouts become attached Homeboy **components** when they already have `homeboy.json`.
> - Data Machine Code `repo@branch` worktrees are skipped by default because they are task-specific."

If they say yes, add `--with-homeboy` to the setup command. Do not imply this is required for wp-coding-agents; it is a recommended power layer for code-heavy installs.

### Question 5: Agent Name

> "What would you like to name your agent? This becomes the agent slug used by Data Machine for identity and memory files.
>
> Default: derived from your site domain (e.g., `example` for example.com, `my-site` for my-site.local)"

Maps to `--agent-slug <name>`. If the user is happy with the default, skip this flag.

### Question 6: Server/Local Details

**For VPS installs:**

> "I'll need some details about your server:
> 1. What's the **server IP address**?
> 2. Do you have **SSH access**? (key or password)
> 3. What **domain** will this site use?"

**For local installs:**

> "Where is WordPress installed on your machine? (e.g., `~/Studio/my-wordpress-website`, `/Applications/MAMP/htdocs/wordpress`)"

### Question 7: For Existing WordPress

If they chose existing WordPress (VPS or local):

> "Where is WordPress installed? (e.g., `/var/www/mysite` or `~/Studio/my-site`)"

---

## Build the Command

Based on their answers, construct the appropriate command:

| Scenario | Command |
|----------|---------|
| Fresh VPS + OpenCode + DM + Discord | `SITE_DOMAIN=example.com ./setup.sh` |
| Fresh VPS + Claude Code + DM | `SITE_DOMAIN=example.com ./setup.sh --runtime claude-code` |
| Fresh VPS + DM + Telegram | `SITE_DOMAIN=example.com ./setup.sh --chat telegram` |
| Fresh VPS + DM, no chat | `SITE_DOMAIN=example.com ./setup.sh --no-chat` |
| Existing VPS + DM | `EXISTING_WP=/var/www/mysite ./setup.sh --existing` |
| Existing VPS + Claude Code | `EXISTING_WP=/var/www/mysite ./setup.sh --existing --runtime claude-code` |
| **Local + OpenCode + DM + Discord** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local` |
| **Local + Claude Code + DM** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime claude-code` |
| **Local + Studio Code + DM** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime studio-code` |
| **Local + multiple runtimes** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime claude-code,studio-code` |
| **Local + recommended Homeboy layer** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --with-homeboy` |
| **Local + DM + Telegram** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --chat telegram` |
| **Local + DM, no chat** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --no-chat` |
| **Local (Studio) with WP_CMD** | `WP_CMD="studio wp" EXISTING_WP=~/Studio/my-site ./setup.sh --local` |
| **Using --wp-path** | `./setup.sh --wp-path ~/Studio/my-site --runtime claude-code` |
| Multisite | `SITE_DOMAIN=example.com ./setup.sh --multisite` |
| Subdomain multisite | `SITE_DOMAIN=example.com ./setup.sh --multisite --subdomain` |

Add `--skip-deps` if nginx, PHP, MySQL, Node are already installed.
Add `--skip-ssl` to skip Let's Encrypt certificate.
Add `--root` to run the agent as root (default is dedicated service user).
Add `--no-skills` to skip WordPress agent skills.
Add `--agent-slug <slug>` to override the Data Machine agent slug.
Add `--with-homeboy` when the user wants the optional Homeboy developer power layer. Homeboy remains external; setup should verify or install the CLI and WordPress extension, create/update a Homeboy project for the WordPress site root, attach eligible Data Machine Code primary workspace checkouts as components, skip `@` worktrees by default, sync `datamachine_code_homeboy_available`, and recompose `AGENTS.md`.

**WordPress Studio note:** If the site runs under WordPress Studio, prefix the command with `WP_CMD="studio wp"` so setup.sh uses Studio's WP-CLI wrapper instead of bare `wp`. Studio is auto-detected when `studio` CLI and `STUDIO.md` are both present.

---

## Confirm Before Proceeding

Before running anything, summarize what you're about to do:

> "Here's the plan:
> - **Server:** 123.45.67.89
> - **Domain:** example.com
> - **Agent name:** example (or custom name)
> - **Type:** Fresh install
> - **Runtime:** OpenCode
> - **Chat bridge:** Kimaki (Discord)
> - **Command:** `SITE_DOMAIN=example.com ./setup.sh`
>
> Does this look right?"

Only continue after explicit confirmation.

---

## Dry Run First

Before running setup for real, recommend a dry run to preview what will happen:

```bash
<constructed command from above> --dry-run
```

This prints every command without executing anything. Review the output to confirm the plan matches expectations, then run again without `--dry-run`.

---

## Run the Setup

### Local Install

Run directly on your machine — no SSH needed:

```bash
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents
<constructed command from above>
```

### VPS Install via SSH

```bash
ssh root@<server-ip>
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents
<constructed command from above>
```

For **migration**, first transfer the database and wp-content:
```bash
# On old server
mysqldump dbname > backup.sql
tar -czf wp-content.tar.gz -C /var/www/oldsite wp-content/

scp backup.sql wp-content.tar.gz root@newserver:/tmp/

# On new server — import, then run setup with --existing
mysql -e "CREATE DATABASE wordpress;" && mysql wordpress < /tmp/backup.sql
mkdir -p /var/www/mysite && tar -xzf /tmp/wp-content.tar.gz -C /var/www/mysite/
```

---

## Post-Setup Verification

After setup.sh completes, verify:

### WordPress

**VPS:**
```bash
wp --allow-root option get siteurl
```

**Local (standard WP-CLI):**
```bash
wp option get siteurl --path=/path/to/site
```

**Local (WordPress Studio):**
```bash
studio wp option get siteurl
```

### Data Machine

**VPS:**
```bash
wp --allow-root plugin list | grep data-machine
```

**Local:**
```bash
wp plugin list --path=/path/to/site | grep data-machine
# or for Studio:
studio wp plugin list | grep data-machine
```

### Coding Agent

**OpenCode:**
```bash
opencode --version
```

**Claude Code:**
```bash
claude --version
```

**Studio Code:**
```bash
studio --version
```

### Kimaki OpenCode Plugins

When setup uses **OpenCode + Kimaki**, verify that the plugin paths written to `opencode.json` exist on disk. OpenCode silently skips missing plugin files, so this is the explicit failure signal for a disabled Data Machine context filter.

**VPS:**
```bash
test -f /opt/kimaki-config/plugins/dm-context-filter.ts && test -f /opt/kimaki-config/plugins/dm-agent-sync.ts
journalctl -u kimaki -n 100 --no-pager | grep 'kimaki-config: WARNING' || true
```

**Local:**
```bash
KIMAKI_PLUGINS_DIR="$(npm root -g)/kimaki/plugins"
test -f "$KIMAKI_PLUGINS_DIR/dm-context-filter.ts" && test -f "$KIMAKI_PLUGINS_DIR/dm-agent-sync.ts"
grep 'kimaki-config: WARNING' "$HOME/.kimaki/kimaki.log" || true
```

If either `test -f` command fails, restart/re-run setup or upgrade before trusting a new OpenCode session. If the log contains a warning about the persistent plugin source dir or required OpenCode plugins, `dm-context-filter.ts` is not guaranteed to be active after restart.

### Homeboy (`--with-homeboy`)

If setup used `--with-homeboy`, verify the optional developer layer explicitly:

```bash
homeboy --version
homeboy extension list
homeboy project show <project-id>
homeboy project components list <project-id>
```

Then verify Data Machine Code can see Homeboy and agent instructions were recomposed:

**VPS or standard WP-CLI:**
```bash
wp option get datamachine_code_homeboy_available --path=/path/to/site
wp datamachine memory compose AGENTS.md --path=/path/to/site
```

**WordPress Studio:**
```bash
studio wp option get datamachine_code_homeboy_available
studio wp datamachine memory compose AGENTS.md
```

Expected model:

```text
WordPress site root
  = Homeboy project

DMC workspace primary checkouts
  = Homeboy components attached to that project

DMC worktrees (`repo@branch`)
  = task-specific ephemeral worktrees skipped by default
```

Do not create `homeboy.json` in the WordPress site root. Do not attach `repo@branch` worktrees by default. Do not modify external component repos unless the user explicitly asks for a Homeboy adoption flow in that repo.

### Site Reachable (VPS)

```bash
curl -I https://yourdomain.com
```

---

## Chat Bridge Post-Setup

### Kimaki (Discord)

**VPS:**
```bash
# Run interactively first to set up bot token
kimaki
# Or set token in systemd: systemctl edit kimaki
# Then start:
systemctl start kimaki
systemctl enable kimaki
```

**Local (macOS — launchd):**
```bash
# Set KIMAKI_BOT_TOKEN in the plist if not already configured
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.wp.kimaki.plist
launchctl kickstart gui/$(id -u)/com.wp.kimaki
```

### cc-connect

**VPS:**
```bash
systemctl start cc-connect
systemctl enable cc-connect
```

**Local (macOS — launchd):**
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.wp.cc-connect.plist
launchctl kickstart gui/$(id -u)/com.wp.cc-connect
```

### Telegram

After setup with `--chat telegram`, configure the bot:

1. **Set environment variables** — `TELEGRAM_BOT_TOKEN` (from @BotFather) and `TELEGRAM_ALLOWED_USER_ID` (your numeric Telegram user ID).

2. **Start the services:**

**VPS (systemd):**
```bash
systemctl start opencode-serve
systemctl start opencode-telegram
systemctl enable opencode-serve opencode-telegram
```

**Local (macOS — launchd):**
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.wp.opencode-serve.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.wp.opencode-telegram.plist
```

3. **Verify:** Send a message to your bot on Telegram — it should respond via OpenCode.

---

Credentials are saved to `~/.wp-coding-agents-credentials` (chmod 600).

---

## When to Use This Skill

Use when the user says things like:
- "Help me install wp-coding-agents on my server"
- "Set up a coding agent on this VPS"
- "Add Claude Code / OpenCode to my existing WordPress site"
- "Set up a local AI agent on my machine"
- "Install wp-coding-agents with WordPress Studio"
- "Set it up with Homeboy"
- "Enable repo-aware Homeboy workflows"

**Do NOT use** for ongoing WordPress management — that's the agent's job after installation.

---

## Troubleshooting

- **WordPress 500 errors:** Check PHP-FPM status, nginx error log, file permissions
- **WP-CLI errors:** Use `--allow-root` on VPS, or `--path=` / `studio wp` locally; verify wp-config.php
- **OpenCode won't start:** Check `node --version` (needs 18+), check `opencode --version`
- **Claude Code won't start:** Check `claude --version`, verify npm install completed
- **Kimaki won't start:** Check `KIMAKI_BOT_TOKEN` in systemd env (VPS) or launchd plist (local), check `journalctl -u kimaki` (VPS) or `launchctl list | grep kimaki` (local)
- **cc-connect won't start:** Check config at `~/.cc-connect/config.toml`, verify `cc-connect` is installed globally
- **Telegram bot won't respond:** Verify `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID` are set, check that both `opencode-serve` and `opencode-telegram` services are running
- **Data Machine not working:** Verify plugin active, run `wp action-scheduler run --allow-root` (VPS) or `studio wp action-scheduler run` (local)
- **Runtime not found:** Check available runtimes with `ls runtimes/`, or install one (`npm install -g opencode-ai` or `npm install -g @anthropic-ai/claude-code`)
- **Homeboy not available in AGENTS.md:** Verify `homeboy --version`, confirm `homeboy extension list` includes the WordPress extension, update `datamachine_code_homeboy_available`, then re-run `wp datamachine memory compose AGENTS.md` or `studio wp datamachine memory compose AGENTS.md`
