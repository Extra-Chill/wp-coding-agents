# Setup Interview

Collect the facts needed to install wp-coding-agents. Do not build commands, run setup, or provide verification matrices from this branch. Output a normalized JSON setup profile for `scripts/compile-setup-profile.mjs`.

## Interview Questions

1. **Install target**
   Ask which target applies:
   - `local` — existing WordPress on the operator's machine.
   - `fresh-vps` — new VPS, new WordPress site.
   - `existing-vps` — WordPress already exists on a server.
   - `migration` — site exists elsewhere and is moving before setup.
   - `external-runtime` — the runtime reaches WordPress through an operator-supplied command transport without mounting its filesystem.

2. **Target details**
   Collect only the fields relevant to the selected target:
   - Local: WordPress root path and whether it is a WordPress Studio site.
   - Fresh VPS: server host/IP, SSH user, domain, and whether SSL should be skipped.
   - Existing VPS: server host/IP, SSH user, WordPress root path, and domain if known.
   - Migration: source backup status, destination server host/IP, SSH user, final WordPress root path, and domain.
   - External runtime: runtime project root, WordPress-side root path, optional WordPress user, and control transport argv. Keep credentials in the runtime environment or credential store rather than argv.

3. **Runtime axis**
   Ask which runtime or runtimes the user wants:
   - `opencode`
   - `claude-code`
   - `codex`
   - `multiple`

   If they choose multiple, collect the desired runtime list. If they are unsure, record `auto` so `setup.sh` can auto-detect.
   External runtimes currently require an explicit `opencode` selection.

4. **Chat bridge axis**
   Ask how the user wants to communicate with the agent:
   - `kimaki` — Discord bridge, common for OpenCode.
   - `cc-connect` — multi-platform bridge, common for Claude Code.
   - `telegram` — Telegram bot for OpenCode.
   - `none` — terminal/SSH/manual only.
   - `auto` — let setup choose the default bridge for the runtime.

   Codex currently has no managed chat bridge in wp-coding-agents; use `none` or `auto` for Codex unless the setup script grows a Codex bridge.

   For Telegram, collect whether `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID` are available.

5. **Codebox / gateway path**
   Ask this only when the user mentions Codebox minions, OpenCode/Kimaki external clients, or WP AI Gateway. Plain Codex runtime selection is handled by the runtime axis above and does not require a provider/gateway path.

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

Return the profile as JSON in this shape so the compiler script can map it deterministically:

```json
{
  "install_target": "local | fresh-vps | existing-vps | migration | external-runtime",
  "target": {
    "ssh_host": "",
    "ssh_user": "",
    "domain": "",
    "wordpress_path": "",
    "runtime_project_root": "",
    "wordpress_user": "",
    "control_transport_argv": [],
    "wordpress_studio": false,
    "migration_backups_ready": false
  },
  "runtime": {
    "selection": "auto | opencode | claude-code | codex | multiple",
    "runtimes": []
  },
  "chat_bridge": {
    "selection": "auto | kimaki | cc-connect | telegram | none",
    "telegram_token_available": false,
    "telegram_allowed_user_id_available": false
  },
  "codex_path": "not-applicable | codebox-minions | external-openai-compatible-endpoint",
  "overlays": {
    "homeboy": false,
    "wordpress_studio": false,
    "multisite": false,
    "subdomain_multisite": false,
    "skip_deps": false,
    "skip_ssl": false,
    "skip_skills": false,
    "root": null
  },
  "agent": {
    "slug": "",
    "name": ""
  },
  "notes": []
}
```

Use empty strings or `false` for unknown optional values. Do not invent defaults beyond recording `auto` where setup should auto-detect.

## Completion Criteria

- The profile identifies the install target.
- The profile separates runtime and bridge selections.
- Optional overlays are independent booleans or explicit values.
- No setup command has been built or run.
