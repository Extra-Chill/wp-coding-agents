# AGENTS.md

WP-CLI: `{{WP_CLI_CMD}}`

### Data Machine

Data Machine is your operating layer — memory, automation, and orchestration via WP-CLI.

**Memory:** Persistent files across sessions. Discover yours: `{{WP_CLI_CMD}} datamachine agent paths`
- Read/write/search memory: `{{WP_CLI_CMD}} datamachine agent read|write|search`
- Update MEMORY.md when you learn something persistent — read it first, append new info.

**Automation:** Self-scheduling workflows that run without human intervention.
- Flows: `{{WP_CLI_CMD}} datamachine flow create|run|list` — scheduled or on-demand tasks
- Pipelines: `{{WP_CLI_CMD}} datamachine pipeline create|list` — multi-step processing chains
- Jobs: `{{WP_CLI_CMD}} datamachine jobs list|retry|summary` — monitor queued work
- Discover available step types: `{{WP_CLI_CMD}} datamachine step-types list`
- Discover available handlers: `{{WP_CLI_CMD}} datamachine handlers list`

**Code (data-machine-code):** Managed git workspace and GitHub integration.
- Workspace: `{{WP_CLI_CMD}} datamachine-code workspace clone|read|write|edit|git`
- GitHub: `{{WP_CLI_CMD}} datamachine-code github issues|pulls|repos|comment`

**System:** `{{WP_CLI_CMD}} datamachine system health|prompts|run`

Use `--help` on any command to discover options and subcommands.

### Abilities

WordPress Abilities are the universal tool surface. Plugins register abilities that are automatically available via WP-CLI, REST API, MCP, and chat. Discover what's available: `{{WP_CLI_CMD}} help abilities`

The tool surface grows as plugins are installed — always discover before assuming what's available.

### WordPress Source

Direct reference material — grep it as needed:
- `wp-content/plugins/` — all plugin source
- `wp-content/themes/` — all theme source
- `wp-includes/` — WordPress core (read-only)

### Multisite

This is a WordPress multisite. Use `--url` to target specific sites:
```
{{WP_CLI_CMD}} --url=site.example.com <command>
```
Without `--url`, commands default to the main site.
