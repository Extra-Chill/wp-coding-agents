# WP Coding Agents

**Composable coding agents for WordPress-powered workspaces.**

`wp-coding-agents` turns a WordPress install into the home base for an AI coding agent. WordPress provides the durable operating layer, Data Machine composes the agent's memory and instructions, a coding runtime executes work, and optional bridges or orchestrators connect the agent to humans and lab environments.

The goal is a focused agent context: each installed component contributes the guidance it owns, and unavailable components stay out of the prompt.

## Who It Is For

Use `wp-coding-agents` when you want:

- A personal or team coding agent with persistent identity, memory, and site-aware tools.
- A local development agent attached to an existing WordPress Studio, MAMP, or manual install.
- An always-on VPS agent that can respond through chat and run scheduled work.
- A generic integration layer that can compose multiple runtimes, bridges, and orchestration tools without hardcoding every workflow into one prompt.

It is not a single bundled agent product. It is the wiring layer that installs and aligns the pieces of a WordPress-native coding-agent stack.

## How It Works

```text
Human
  │
  ├─ terminal
  ├─ Discord / chat bridge
  └─ automation / dispatch
        │
        ▼
Coding runtime
  ├─ OpenCode
  ├─ Claude Code
  └─ Codex
        │
        ▼
WordPress + Data Machine
  ├─ agent identity and memory
  ├─ composed AGENTS.md guidance
  ├─ abilities exposed through WordPress
  ├─ flows, jobs, and scheduled work
  └─ optional developer/orchestration extensions
```

Data Machine is the always-present composition layer. It owns the persistent agent files and generated guidance surface. `wp-coding-agents` installs the selected runtime, registers the concise generic WordPress coding contract, and adds guidance only for integrations that are actually available.

## The Prompt Model

The agent should know only what it can use.

- **Data Machine** is always present and composes `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `USER.md`, and shared site guidance.
- **Coding runtimes** add only their runtime-specific configuration, such as OpenCode instructions, Claude Code `@` includes, or Codex's managed `AGENTS.override.md`.
- **Chat bridges** describe the human communication surface when that bridge is selected.
- **Developer orchestration layers** add guidance only when installed and verified.
- **Unavailable tools** do not get stub instructions, fallback recipes, or negative constraints.

For example, a Kimaki install should know Kimaki is the Discord surface. It should not learn generic Kimaki worktree, tunnel, or session-fanout recipes when those responsibilities belong to other installed components. Likewise, Homeboy guidance appears only when Homeboy is available, and workspace/worktree guidance comes from the Data Machine Code layer.

## What It Enables

### Local Agent

Run an agent from an existing local WordPress site and keep its context grounded in that site.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local
cd ~/Studio/my-site && opencode
```

Use Codex as the terminal runtime when you want the site context in a Codex session without a chat bridge:

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime codex
cd ~/Studio/my-site && codex
```

### Chat-Connected Agent

Connect the coding runtime to a human chat surface for planning, status, file uploads, and review loops.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --chat kimaki
cd ~/Studio/my-site && kimaki
```

### Always-On VPS Agent

Install WordPress, Data Machine, the runtime, and a chat bridge on a dedicated server.

```bash
SITE_DOMAIN=example.com ./setup.sh
```

### Repo-Aware Developer Workflows

Use Data Machine Code workspace management and optional orchestration tools to keep repository work isolated, reviewable, and tied back to the WordPress agent context.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --with-homeboy
```

When an optional orchestrator is available, its own presence-gated AGENTS section explains the supported workflow. When it is absent, the prompt does not mention its commands.

## Components

| Component | Role | Availability |
| --- | --- | --- |
| WordPress | Site runtime, plugin host, WP-CLI surface | Existing local install or installed on VPS |
| Data Machine | Agent identity, memory, composed guidance, abilities, flows, jobs | Always installed |
| OpenCode | Coding runtime | Selected or auto-detected |
| Claude Code | Coding runtime | Selected or auto-detected |
| Codex | Coding runtime | Selected or auto-detected |
| Data Machine Code | Workspace, git, GitHub, and worktree integration | Installed with the Data Machine stack |
| Kimaki | Discord bridge for OpenCode sessions | Optional chat bridge |
| cc-connect | Multi-platform bridge, commonly used with Claude Code | Optional chat bridge |
| opencode-telegram | Telegram bridge for OpenCode | Optional chat bridge |
| Homeboy | Optional repo-aware task/lab orchestration layer | Enabled with `--with-homeboy` when available |
| AI Provider for Claude Code | WP AI Client provider backed by Claude Code OAuth credentials | Installed when Claude Code is selected or detected |

## Installation

### Local

Use an existing WordPress install.

```bash
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents

EXISTING_WP=~/Studio/my-site ./setup.sh --local
```

Select a runtime explicitly when needed:

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime opencode
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime claude-code
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime codex
```

### VPS

Run setup from the server.

```bash
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents

SITE_DOMAIN=example.com ./setup.sh
```

For agent-assisted setup, give your local coding agent the setup entrypoint:

```text
operator-entrypoints/wp-coding-agents-setup/setup.md
```

## Common Setup Options

| Flag | Description |
| --- | --- |
| `--runtime <name>` | Coding runtime: `opencode`, `claude-code`, or `codex`. Auto-detected when omitted. |
| `--posture <name>` | `engineering` (default) or `managed`. See [Install Posture](#install-posture). |
| `--local` | Local machine mode. Skips server infrastructure. |
| `--existing` | Add to an existing WordPress install. |
| `--wp-path <path>` | WordPress root path. Implies `--existing`. |
| `--agent-slug <slug>` | Override the Data Machine agent slug. |
| `--kimaki-unit <unit>` | Target a Kimaki systemd instance, such as `kimaki-example.service`. |
| `--kimaki-data-dir <path>` | Override that Kimaki instance's state directory. |
| `--kimaki-lock-port <port>` | Override that Kimaki instance's lock port. |
| `--chat <bridge>` | Chat bridge: `kimaki`, `cc-connect`, or `telegram`. Codex currently runs without a managed chat bridge. |
| `--no-chat` | Skip chat bridge setup. |
| `--with-homeboy` | Enable optional Homeboy project/lab integration when available. |
| `--with-ai-gateway` | Enable optional [WP AI Gateway](https://github.com/Automattic/wp-ai-gateway) setup for OpenCode runtimes. |
| `--ai-gateway-provider <id>` | WordPress AI Client backend provider for the gateway route (default: `openai`). |
| `--ai-gateway-model <id>` | Backend model for the gateway route (default: `gpt-4o-mini`). |
| `--ai-gateway-opencode-model <id>` | OpenCode-facing gateway model ID (default: `site-default`). |
| `--rotate-ai-gateway-token` | Mint a replacement gateway token instead of reusing `.opencode/wp-ai-gateway.env`. |
| `--multisite` | Configure WordPress multisite. |
| `--subdomain` | Use subdomain multisite. |
| `--no-skills` | Skip installing bundled agent skills. |
| `--dry-run` | Print planned actions without applying them. |

Run `./setup.sh --help` for the complete setup surface.

## Install Posture

Posture is the agent's relationship to the installed WordPress source. It is a
declared intent rather than a detected fact, and it is the single input that
decides the plugin set, every runtime permission surface, and the AGENTS.md
guidance the agent reads.

| | `engineering` (default) | `managed` |
| --- | --- | --- |
| `wp-content/themes/`, `wp-content/plugins/` | read-only reference | **editable in place** |
| `wp-includes/` | read-only | read-only |
| Data Machine Code | installed | not installed |
| Workspace, git, GitHub | the agent's workflow | not present |
| How changes reach version control | the agent commits and opens pull requests | captured out-of-band by the operator |

**Engineering** is the developer setup: the installed tree is reference
material, and every code change happens in a Data Machine Code workspace so it
is tracked in git and reviewed through GitHub.

**Managed** is for managed agentic hosting, where a non-technical owner should
never have to deal with pull requests. The agent edits the live theme and
plugins directly and its changes are live on save; something outside the box —
for example a scheduled `homeboy harvest` — captures them into git as restore
points.

A single source of truth (`lib/source-policy.sh`) derives the runtime
permissions and the generated guidance from the chosen posture, so the prose
cannot tell the agent to do something the permissions then block.

The chosen posture is recorded on the install, so `./upgrade.sh` converges to it
without repeating the flag. Pass `--posture` to either script to change it.

On VPS hosts with multiple Kimaki services, setup and upgrade select the unit
whose `WorkingDirectory=` exactly matches the WordPress site path. Ambiguous or
unmatched installed units fail safely; pass `--kimaki-unit` to select or create
an instance explicitly. The traditional single-instance defaults remain
`kimaki.service` and `<service-home>/.kimaki`.

## Runtime And Bridge Notes

### OpenCode

OpenCode uses `opencode.json` with Data Machine-composed instruction files. Kimaki is the default chat bridge for OpenCode when chat is enabled.

Pass `--with-ai-gateway` to opt OpenCode into this site's [WP AI Gateway](https://github.com/Automattic/wp-ai-gateway) endpoint. Setup installs the gateway/provider stack, configures the backend route via WP-CLI, mints (or reuses) a gateway token, and writes an OpenAI-compatible `provider.wp-ai-gateway` entry so clients receive only the gateway token while upstream credentials stay in WordPress. Native OpenCode auth is untouched unless gateway mode is opted in.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime opencode \
  --with-ai-gateway --ai-gateway-provider openai --ai-gateway-model gpt-4o-mini
```

### Claude Code

Claude Code uses `CLAUDE.md` with generated `@` includes. A SessionStart hook refreshes the Data Machine memory includes for each session.

When Claude Code is selected or detected, `wp-coding-agents` installs the carried `ai-provider-for-claude-code` plugin so WordPress AI Client consumers can use the local Claude Code OAuth-backed provider when appropriate.

### Codex

Codex reads `AGENTS.override.md` from the WordPress site root when present, before falling back to `AGENTS.md`. Because Codex does not load arbitrary instruction files from an `instructions` array or Claude-style `@` includes, setup and upgrade generate a Codex-owned `AGENTS.override.md` from the shared `AGENTS.md` plus the local Data Machine memory files.

Keeping the Codex memory mirror in `AGENTS.override.md` avoids polluting the shared `AGENTS.md` that OpenCode also reads. On a site with both runtimes, OpenCode keeps using `AGENTS.md` plus `opencode.json` instructions, while Codex gets the same site guidance and memory through its generated override.

Setup installs the managed upgrade skill into `.agents/skills`, registers Codex thread attribution for Data Machine Code when available, and leaves global Codex config and auth state alone.

Codex does not currently have a managed chat bridge in this repo, so setup defaults to terminal/manual operation:

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime codex
cd ~/Studio/my-site && codex
```

### Kimaki

Kimaki is the Discord surface for OpenCode. Managed installs replace Kimaki's generic runtime prompt with a small bridge prompt so orchestration, workspace, tunnel, and preview guidance can come from the installed components that own those capabilities.

Kimaki-specific OpenCode plugins are synced into Kimaki's config directory and restored across package updates. The managed-plugin rig verifies that contract:

```bash
bash tests/kimaki-managed-plugin-rig.sh
```

### cc-connect

cc-connect is the default bridge for Claude Code. It writes a project config pointing at the WordPress site root and can run under launchd or systemd depending on install mode.

### Telegram

Telegram support uses `opencode-telegram`. Provide `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USER_ID` during setup.

## Data Machine Memory

Data Machine manages the agent's persistent files:

| File | Scope | Purpose |
| --- | --- | --- |
| `SITE.md` | Site | Generated WordPress context |
| `RULES.md` | Site | Shared behavioral rules |
| `SOUL.md` | Agent | Agent identity and voice |
| `MEMORY.md` | Agent | Persistent project knowledge |
| `USER.md` | User | Human profile and preferences |

The selected runtime reads this memory at session start. OpenCode references the files from `opencode.json`, Claude Code uses generated `@` includes, and Codex receives the same file contents through a generated site-root `AGENTS.override.md`. The agent can update memory through Data Machine instead of relying on runtime-specific memory features.

## Abilities And Dispatch

Data Machine exposes tools through WordPress abilities. `wp-coding-agents` adds the local CLI transport that lets Data Machine send messages through installed chat bridges via the `agents/dispatch-message` contract.

Bridge channel registrations are conditional: only installed bridges register channels, and the generated guidance reflects only those channels.

## Verification

Useful local checks:

```bash
bash tests/agents-md-guidance.sh
bash tests/homeboy-agents-md.sh
bash tests/kimaki-managed-plugin-rig.sh
node tests/effective-prompt/run.mjs --verbose
```

Use setup output and operator entrypoints for environment-specific verification commands. The generated summary is the source of truth for service names, paths, and bridge restart commands.

## Upgrades

Installed agents receive an `upgrade-wp-coding-agents` skill. The skill runs `upgrade.sh`, preserves user state, syncs managed bridge/runtime files, and prints verification and restart commands for the detected environment.

Run `./upgrade.sh --help` for upgrade flags.

## Requirements

### VPS

- Ubuntu/Debian-style Linux server
- Node.js 18+
- PHP 8.0+
- MySQL or MariaDB
- nginx
- WP-CLI

### Local

- macOS or Linux desktop
- Existing WordPress install
- Node.js 18+
- WP-CLI or WordPress Studio's `studio wp` wrapper

## Related Projects

- [Data Machine](https://github.com/Extra-Chill/data-machine) — WordPress-native agent memory, abilities, flows, and jobs.
- [Data Machine Code](https://github.com/Extra-Chill/data-machine-code) — Repository, workspace, git, and GitHub integration for Data Machine.
- [Homeboy](https://github.com/Extra-Chill/homeboy) — Optional orchestration/lab layer for repo-aware coding workflows.
- [Kimaki](https://kimaki.xyz) — Discord bridge used by OpenCode installs.

## Contributing

Issues and PRs are welcome.

## License

MIT — see [LICENSE](LICENSE).

---

Built by [Extra Chill](https://extrachill.com).
