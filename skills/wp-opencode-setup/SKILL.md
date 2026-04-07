---
name: wp-opencode-setup
description: "Install wp-opencode on a VPS or local machine. Use this skill from your LOCAL machine to deploy a self-contained WordPress + OpenCode environment on a remote server, or to set up a local agent on your own machine."
compatibility: "For VPS: requires SSH access, Ubuntu/Debian recommended. For local: requires an existing WordPress install (WordPress Studio, MAMP, manual, etc.) and Node.js."
---

# WP-OpenCode Setup Skill

**Purpose:** Help a user install wp-opencode on a remote VPS or their local machine.

This skill is for the **local agent** (Claude Code, Cursor, etc.) assisting with installation. Once OpenCode is running on the VPS with a chat bridge (e.g., Kimaki for Discord), this skill is no longer needed — the VPS agent takes over. For local installs, the agent runs directly on the user's machine.

---

## FIRST: Interview the User

**Do NOT proceed with installation until you've asked these questions and gotten answers.**

### Question 1: Installation Type

> "Are you setting up a **fresh WordPress site on a VPS**, do you have an **existing WordPress site**, or do you want to run **locally on your own machine**?"

**Options:**
- **Fresh VPS install** — New VPS, new WordPress site
- **Existing WordPress (VPS)** — Site already running on a server, just add OpenCode
- **Local install** — Use an existing WordPress on your own machine (WordPress Studio, MAMP, etc.)
- **Migration** — Site exists elsewhere, moving to this VPS

### Question 2: Autonomous Operation

> "Do you want **autonomous operation** capabilities? This includes Data Machine — a self-scheduling system that lets your agent set reminders, queue tasks, and operate 24/7 without human intervention.
>
> - **Yes (recommended for content sites)** — Full autonomy, self-scheduling, proactive operation
> - **No (simpler setup)** — Agent responds when asked, no self-scheduling overhead"

### Question 3: Chat Bridge

> "How do you want to communicate with your agent?
>
> - **Discord (via Kimaki)** — Default. Your agent gets a Discord bot.
> - **No chat bridge** — Run OpenCode manually via SSH when needed."

### Question 4: Server/Local Details

**For VPS installs:**

> "I'll need some details about your server:
> 1. What's the **server IP address**?
> 2. Do you have **SSH access**? (key or password)
> 3. What **domain** will this site use?"

**For local installs:**

> "Where is WordPress installed on your machine? (e.g., `~/Studio/my-wordpress-website`, `/Applications/MAMP/htdocs/wordpress`)"

### Question 5: For Existing WordPress

If they chose existing WordPress (VPS or local):

> "Where is WordPress installed? (e.g., `/var/www/mysite` or `~/Studio/my-site`)"

---

## Build the Command

Based on their answers, construct the appropriate command:

| Scenario | Command |
|----------|---------|
| Fresh VPS + DM + Discord | `SITE_DOMAIN=example.com ./setup.sh` |
| Fresh VPS + DM, no Discord | `SITE_DOMAIN=example.com ./setup.sh --no-chat` |
| Fresh VPS, no DM | `SITE_DOMAIN=example.com ./setup.sh --no-data-machine` |
| Existing VPS + DM | `EXISTING_WP=/var/www/mysite ./setup.sh --existing` |
| **Local + DM + Discord** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local` |
| **Local + DM, no Discord** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --no-chat` |
| **Local, no DM** | `EXISTING_WP=~/Studio/my-site ./setup.sh --local --no-data-machine` |
| Multisite | `SITE_DOMAIN=example.com ./setup.sh --multisite` |
| Subdomain multisite | `SITE_DOMAIN=example.com ./setup.sh --multisite --subdomain` |

Add `--skip-deps` if nginx, PHP, MySQL, Node are already installed.
Add `--skip-ssl` to skip Let's Encrypt certificate.
Add `--root` to run the agent as root (default is dedicated service user).
Add `--no-skills` to skip WordPress agent skills.

---

## Confirm Before Proceeding

Before running anything, summarize what you're about to do:

> "Here's the plan:
> - **Server:** 123.45.67.89
> - **Domain:** example.com
> - **Type:** Fresh install
> - **Data Machine:** Yes
> - **Chat bridge:** Kimaki (Discord)
> - **Command:** `SITE_DOMAIN=example.com ./setup.sh`
>
> Does this look right?"

Only continue after explicit confirmation.

---

## Run the Setup

### Local Install

Run directly on your machine — no SSH needed:

```bash
git clone https://github.com/Extra-Chill/wp-opencode.git
cd wp-opencode
<constructed command from above>
```

### VPS Install via SSH

```bash
ssh root@<server-ip>
git clone https://github.com/Extra-Chill/wp-opencode.git
cd wp-opencode
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

```bash
# WordPress
wp --allow-root option get siteurl

# Data Machine (if installed)
wp --allow-root plugin list | grep data-machine

# OpenCode
opencode --version

# Site reachable
curl -I https://yourdomain.com
```

Then complete chat bridge setup:
```bash
# If using Kimaki — run interactively first to set up bot token
kimaki
# Or set token in systemd: systemctl edit kimaki
# Then start: systemctl start kimaki
```

Credentials are saved to `~/.wp-opencode-credentials` (chmod 600).

---

## When to Use This Skill

Use when the user says things like:
- "Help me install wp-opencode on my server"
- "Set up OpenCode on this VPS"
- "Add OpenCode to my existing WordPress site"
- "Set up a local AI agent on my machine"
- "Install wp-opencode with WordPress Studio"

**Do NOT use** for ongoing WordPress management — that's the agent's job after installation.

---

## Troubleshooting

- **WordPress 500 errors:** Check PHP-FPM status, nginx error log, file permissions
- **WP-CLI errors:** Use `--allow-root`, verify wp-config.php
- **OpenCode won't start:** Check `node --version` (needs 18+), check `opencode --version`
- **Kimaki won't start:** Check `KIMAKI_BOT_TOKEN` in systemd env, check `journalctl -u kimaki`
- **Data Machine not working:** Verify plugin active, run `wp action-scheduler run --allow-root`
