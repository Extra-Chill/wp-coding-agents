---
name: wp-coding-agents-setup-interview
description: "Collect a normalized wp-coding-agents setup profile without embedding install execution details or verification matrices."
compatibility: "Use before wp-coding-agents-setup-skill-compiler. Does not run setup commands."
---

# WP Coding Agents Setup Interview

Collect the facts needed to install wp-coding-agents. Do not build commands, run setup, or provide verification matrices from this skill. Output a normalized setup profile for `wp-coding-agents-setup-skill-compiler`.

## Interview Questions

1. **Install target**
   Ask which target applies:
   - `local` — existing WordPress on the operator's machine.
   - `fresh-vps` — new VPS, new WordPress site.
   - `existing-vps` — WordPress already exists on a server.
   - `migration` — site exists elsewhere and is moving before setup.

2. **Target details**
   Collect only the fields relevant to the selected target:
   - Local: WordPress root path and whether it is a WordPress Studio site.
   - Fresh VPS: server host/IP, SSH user, domain, and whether SSL should be skipped.
   - Existing VPS: server host/IP, SSH user, WordPress root path, and domain if known.
   - Migration: source backup status, destination server host/IP, SSH user, final WordPress root path, and domain.

3. **Runtime axis**
   Ask which runtime or runtimes the user wants:
   - `opencode`
   - `claude-code`
   - `studio-code`
   - `multiple`

   If they choose multiple, collect the comma-separated runtime list. If they are unsure, record `auto` so `setup.sh` can auto-detect.

4. **Chat bridge axis**
   Ask how the user wants to communicate with the agent:
   - `kimaki` — Discord bridge, common for OpenCode.
   - `cc-connect` — multi-platform bridge, common for Claude Code.
   - `telegram` — Telegram bot for OpenCode.
   - `none` — terminal/SSH/manual only.
   - `auto` — let setup choose the default bridge for the runtime.

   For Telegram, collect whether `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID` are available.

5. **Codex / gateway path**
   Ask this only when the user mentions Codex, Codebox minions, OpenCode/Kimaki external clients, or WP AI Gateway.

   Record one of:
   - `codebox-minions` — provider auth is inherited inside Codebox; WP AI Gateway is not required.
   - `external-openai-compatible-endpoint` — optional WP AI Gateway path for external OpenCode/Kimaki clients.
   - `not-applicable`

6. **Optional overlays**
   Collect booleans or values for:
   - Homeboy developer layer.
   - WordPress Studio WP-CLI wrapper.
   - Multisite.
   - Subdomain multisite.
   - Root WP-CLI or dedicated service user preference.
   - Dependency install skip.
   - Skills install skip.

7. **Agent identity**
   Ask for the agent slug and display name only when the user wants to override defaults. Defaults come from the site domain or blog name.

## Output Shape

Return the profile in this shape so the compiler can map it deterministically:

```yaml
install_target: local | fresh-vps | existing-vps | migration
target:
  ssh_host: ""
  ssh_user: ""
  domain: ""
  wordpress_path: ""
  wordpress_studio: false
  migration_backups_ready: false
runtime:
  selection: auto | opencode | claude-code | studio-code | multiple
  runtimes: []
chat_bridge:
  selection: auto | kimaki | cc-connect | telegram | none
  telegram_token_available: false
  telegram_allowed_user_id_available: false
codex_path: not-applicable | codebox-minions | external-openai-compatible-endpoint
overlays:
  homeboy: false
  wordpress_studio: false
  multisite: false
  subdomain_multisite: false
  skip_deps: false
  skip_ssl: false
  skip_skills: false
  root: null
agent:
  slug: ""
  name: ""
notes: []
```

Use empty strings or `false` for unknown optional values. Do not invent defaults beyond recording `auto` where setup should auto-detect.

## Completion Criteria

- The profile identifies the install target.
- The profile separates runtime and bridge selections.
- Optional overlays are independent booleans or explicit values.
- No setup command has been built or run.
