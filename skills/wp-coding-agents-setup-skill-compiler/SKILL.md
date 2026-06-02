---
name: wp-coding-agents-setup-skill-compiler
description: "Compile a normalized wp-coding-agents setup profile into exact setup.sh flags, dry-run command, and relevant runtime, bridge, and verification overlays."
compatibility: "Use after wp-coding-agents-setup-interview. Requires access to the wp-coding-agents repo so setup.sh --help can be checked."
---

# WP Coding Agents Setup Skill Compiler

Convert a setup profile into exact commands and verification overlays. Keep script behavior in `setup.sh`; this skill owns the axis mapping and operator guidance.

Always run `./setup.sh --help` in the repo before finalizing a command so the compiled flags match the current script.

## Axis Mapping

### Install Target

| Profile value | Command shape |
|---|---|
| `local` | `EXISTING_WP=<wordpress_path> ./setup.sh --local` |
| `fresh-vps` | `SITE_DOMAIN=<domain> ./setup.sh` |
| `existing-vps` | `EXISTING_WP=<wordpress_path> ./setup.sh --existing` |
| `migration` | Import database and `wp-content` first, then use `EXISTING_WP=<wordpress_path> ./setup.sh --existing` |

When `target.wordpress_studio` or `overlays.wordpress_studio` is true, prefix the command with `WP_CMD="studio wp"`.

### Runtime

| Profile value | Flags |
|---|---|
| `auto` | omit `--runtime` |
| `opencode` | `--runtime opencode` |
| `claude-code` | `--runtime claude-code` |
| `studio-code` | `--runtime studio-code` |
| `multiple` | `--runtime <comma-separated runtimes>` |

Runtime overlays:

- OpenCode: verify `opencode --version`; if paired with Kimaki, verify managed OpenCode plugin paths.
- Claude Code: verify `claude --version`; use the script-generated `CLAUDE.md` and MCP config.
- Studio Code: verify `studio --version`; use `WP_CMD="studio wp"` for WordPress Studio sites.
- Multiple: run verification for each selected runtime.

### Chat Bridge

| Profile value | Flags |
|---|---|
| `auto` | omit chat flags |
| `kimaki` | `--chat kimaki` |
| `cc-connect` | `--chat cc-connect` |
| `telegram` | `--chat telegram` |
| `none` | `--no-chat` |

Bridge overlays:

- Kimaki: verify bot token/service or launchd configuration after setup; do not restart an existing live bridge without user approval.
- cc-connect: verify config and service/launchd instructions from setup output.
- Telegram: require `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID`; verify the bot responds after services start.
- None: verify the runtime can be started manually in the terminal or over SSH.

### Optional Overlays

| Profile field | Flags or environment |
|---|---|
| `overlays.homeboy` | `--with-homeboy` |
| `overlays.multisite` | `--multisite` |
| `overlays.subdomain_multisite` | `--subdomain` with `--multisite` |
| `overlays.skip_deps` | `--skip-deps` |
| `overlays.skip_ssl` | `--skip-ssl` |
| `overlays.skip_skills` | `--no-skills` |
| `overlays.root == true` | `--root` |
| `overlays.root == false` | `--non-root` |
| `agent.slug` | `--agent-slug <slug>` |
| `agent.name` | `--agent-name <name>` |

Homeboy overlay policy:

- Homeboy is optional and external to wp-coding-agents.
- The WordPress site root is the Homeboy project.
- Data Machine Code primary workspace checkouts can be attached as components when eligible.
- `repo@branch` worktrees stay skipped by default.
- Do not create `homeboy.json` in the WordPress site root to fix a missing project.

Codex / gateway overlay policy:

- `codebox-minions`: verify WordPress AI Client/provider and Codebox auth inheritance. Do not require WP AI Gateway.
- `external-openai-compatible-endpoint`: configure WP AI Gateway only when the operator wants external OpenCode/Kimaki clients to call WordPress as an OpenAI-compatible endpoint.

## Compile The Command

1. Start with the install target command shape.
2. Add runtime flags from the runtime axis.
3. Add bridge flags from the chat bridge axis.
4. Add optional overlay flags.
5. Add environment variables before the command when needed.
6. Produce both commands:
   - dry-run: append `--dry-run`.
   - apply: same command without `--dry-run`.

Examples:

```bash
EXISTING_WP=~/Studio/my-site WP_CMD="studio wp" ./setup.sh --local --runtime studio-code --chat cc-connect --dry-run
SITE_DOMAIN=example.com ./setup.sh --runtime claude-code --with-homeboy --dry-run
EXISTING_WP=/var/www/mysite ./setup.sh --existing --runtime opencode --chat kimaki --dry-run
```

## Verification Overlays

Always verify WordPress and Data Machine first:

```bash
wp option get siteurl --path=/path/to/site
wp plugin list --path=/path/to/site | grep data-machine
```

For WordPress Studio:

```bash
studio wp option get siteurl
studio wp plugin list | grep data-machine
```

Runtime checks:

```bash
opencode --version
claude --version
studio --version
```

Kimaki + OpenCode plugin checks:

```bash
KIMAKI_PLUGINS_DIR="$(npm root -g)/kimaki/plugins"
test -f "$KIMAKI_PLUGINS_DIR/dm-context-filter.ts" && test -f "$KIMAKI_PLUGINS_DIR/dm-agent-sync.ts"
```

On VPS Kimaki installs, use the path and commands emitted by setup output. Inspect startup logs for `kimaki-config: WARNING` before trusting a new OpenCode session.

Homeboy checks when `--with-homeboy` was used:

```bash
homeboy --version
homeboy extension list
homeboy project show <project-id>
homeboy project components list <project-id>
wp option get datamachine_code_homeboy_available --path=/path/to/site
wp datamachine memory compose AGENTS.md --path=/path/to/site
```

For WordPress Studio Homeboy verification, use `studio wp option get datamachine_code_homeboy_available` and `studio wp datamachine memory compose AGENTS.md`.

Codex/Codebox provider checks when selected:

```bash
wp plugin list | grep -E 'php-ai-client|ai-provider-for-openai|wp-codebox'
wp plugin is-active ai-provider-for-openai
wp plugin is-active wp-codebox
```

Gateway checks only when the external endpoint path is selected:

```bash
wp plugin is-active wp-ai-gateway
wp ai-gateway status
```

## Output Shape

Return a concise compiled plan:

```yaml
summary:
  target: ""
  runtime_axis: ""
  bridge_axis: ""
  overlays: []
commands:
  dry_run: ""
  apply: ""
verification:
  wordpress: []
  data_machine: []
  runtime: []
  bridge: []
  optional_overlays: []
warnings: []
```

## Completion Criteria

- The command maps each profile axis independently.
- The dry-run command is present and is the first command to run.
- Verification overlays match the selected runtime, bridge, and options.
- The plan does not require restarting a live chat bridge unless the user explicitly asks.
