# AGENTS.md — WordPress + Data Machine + OpenCode

## Every Session

Before doing anything:
1. Your SOUL.md, USER.md, and MEMORY.md are auto-injected from Data Machine agent files
2. Check the task you received — execute it, report back

## WordPress Environment

Site root: `{{SITE_PATH}}`
WP-CLI: `wp --allow-root --path={{SITE_PATH}}`

### Data Machine (your brain)

Your memory files (SOUL.md, USER.md, MEMORY.md) are auto-injected into every session.

Data Machine is fully discoverable via WP-CLI:
```bash
wp datamachine                          # See all command groups
wp help datamachine <group>             # See subcommands in any group
wp help datamachine <group> <command>   # Full usage, flags, and examples
wp datamachine agent paths --allow-root # Discover your memory file paths
```

For source-level understanding, grep the local codebase:
```bash
grep -r "pattern" wp-content/plugins/<plugin>/   # Plugin source
grep -r "pattern" wp-content/themes/<theme>/      # Theme source
```

### Update MEMORY.md when you learn something new:
```bash
wp datamachine agent paths --format=table --allow-root
# Then read and update it carefully — preserve existing content, append new info
```

### Multisite

If this is a WordPress multisite, use `--url` to target specific sites:
```bash
wp --allow-root --url=site.example.com <command>
```

Without `--url`, commands default to the main site.

## Tools Available

- `wp` — WordPress CLI (always use --allow-root). Fully discoverable: `wp help <command>`
- `wp datamachine` — Data Machine CLI. Discoverable: `wp help datamachine <group>`
- `gh` — GitHub CLI (if authenticated)
- `git` — Version control
- Standard Unix tools (curl, grep, sed, etc.)

When in doubt about any command, use `--help` to discover usage. Don't memorize — discover.

## Git Discipline

1. Identify the repo
2. Clone/pull
3. Make changes
4. Commit with meaningful message
5. Push

## Coding Standards

1. PLAN FIRST — state what stays, adds, removes
2. No dead variables
3. No defensive fallbacks hiding init failures
4. Follow existing codebase patterns
5. Test before committing
6. Comprehensive changes — don't leave old code behind

## Safety

- Don't leak private data
- Don't run destructive commands without asking
- NEVER deploy without being told to
- When in doubt, ask
