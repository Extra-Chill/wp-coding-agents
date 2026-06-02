---
name: wp-coding-agents-setup-skill-compiler
description: "Compile a normalized wp-coding-agents setup profile into exact setup.sh flags, dry-run command, and relevant runtime, bridge, and verification overlay names."
compatibility: "Use after wp-coding-agents-setup-interview. Requires access to the wp-coding-agents repo so setup.sh --help can be checked."
---

# WP Coding Agents Setup Skill Compiler

Convert a setup profile into exact commands and verification overlay names. Keep script behavior in `setup.sh`; this skill owns the axis mapping and operator guidance. Use `wp-coding-agents-setup-verify` for concrete verification command recipes.

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
| `multiple` | omit `--runtime` for auto-detected multi-runtime skill installation, or use one primary runtime and add others later with separate `--runtime-only --runtime <name>` passes |

Runtime overlay names:

- `runtime-opencode`
- `runtime-claude-code`
- `runtime-studio-code`
- `runtime-multiple`

Do not compile comma-separated runtimes into `--runtime`. `setup.sh` treats explicit `--runtime` as one runtime file name. When the user wants multiple runtimes on the first setup, omit `--runtime` and let setup auto-detect all installed runtimes while selecting one primary runtime. When the user needs to add a specific runtime later, compile a separate `--runtime-only --runtime <name>` command after the main setup.

### Chat Bridge

| Profile value | Flags |
|---|---|
| `auto` | omit chat flags |
| `kimaki` | `--chat kimaki` |
| `cc-connect` | `--chat cc-connect` |
| `telegram` | `--chat telegram` |
| `none` | `--no-chat` |

Bridge overlay names:

- `bridge-kimaki`
- `bridge-cc-connect`
- `bridge-telegram`
- `bridge-none`

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
6. Produce verification overlay names from the selected target, runtime, bridge, and optional overlays.
7. Produce both commands:
   - dry-run: append `--dry-run`.
   - apply: same command without `--dry-run`.

Examples:

```bash
EXISTING_WP=~/Studio/my-site WP_CMD="studio wp" ./setup.sh --local --runtime studio-code --chat cc-connect --dry-run
SITE_DOMAIN=example.com ./setup.sh --runtime claude-code --with-homeboy --dry-run
EXISTING_WP=/var/www/mysite ./setup.sh --existing --runtime opencode --chat kimaki --dry-run
```

## Verification Overlay Names

Always include:

- `verify-wordpress`
- `verify-data-machine`

Add target overlays:

- `verify-wordpress-studio` when `target.wordpress_studio` or `overlays.wordpress_studio` is true.
- `verify-vps-reachable` for fresh VPS and existing VPS targets.

Add runtime overlays:

- `verify-runtime-opencode` for OpenCode.
- `verify-runtime-claude-code` for Claude Code.
- `verify-runtime-studio-code` for Studio Code.
- `verify-runtime-multiple` when the profile selected multiple runtimes.

Add bridge overlays:

- `verify-bridge-kimaki` for Kimaki.
- `verify-bridge-kimaki-opencode-plugins` when Kimaki and OpenCode are both selected or detected.
- `verify-bridge-cc-connect` for cc-connect.
- `verify-bridge-telegram` for Telegram.
- `verify-bridge-none` when chat is disabled.

Add optional overlays:

- `verify-homeboy` when `--with-homeboy` is compiled.
- `verify-codex-codebox-provider` for `codex_path: codebox-minions`.
- `verify-wp-ai-gateway` for `codex_path: external-openai-compatible-endpoint`.

Pass these names to `wp-coding-agents-setup-verify` after setup completes. Do not inline the command recipes here.

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
  overlays: []
follow_up_commands: []
warnings: []
```

## Completion Criteria

- The command maps each profile axis independently.
- The dry-run command is present and is the first command to run.
- Verification overlay names match the selected runtime, bridge, and options.
- The plan does not require restarting a live chat bridge unless the user explicitly asks.
