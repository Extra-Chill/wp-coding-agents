# Changelog

## Unreleased

### Added
- Phase 4.5: Create Data Machine agent during setup with scaffolded SOUL.md and MEMORY.md (#15)
- `AGENT_SLUG` environment variable to override the auto-derived agent slug
- Agent slug shown in setup completion summary and saved to credentials file
- `--multisite` flag for fresh installs — converts WordPress to multisite (subdirectory by default)
- `--subdomain` flag — use with `--multisite` for subdomain-based multisite (requires wildcard DNS)
- `--no-skills` flag — skip WordPress agent skills installation
- Multisite auto-detection for `--existing` mode
- Per-site Data Machine activation on multisite (uses `--url` flag, not network activation)
- Nginx configs for both subdomain and subdirectory multisite
- Wildcard SSL guidance for subdomain multisite installs
- WordPress agent skills cloned dynamically from [WordPress/agent-skills](https://github.com/WordPress/agent-skills) at install time
- Data Machine skill (bundled)
- `wp-opencode-setup` skill for local agents assisting with installation
- `README.md`, `LICENSE` (MIT), `VERSION`
- `docs/changelog.md`

## 0.1.0 - 2026-02-25

### Added
- Initial release
- `setup.sh` with 9-phase provisioning (deps, database, WordPress, DM, nginx, SSL, service user, OpenCode, chat bridge)
- `--existing` mode for adding OpenCode to existing WordPress installations
- `--no-data-machine` flag to skip Data Machine plugin
- `--no-chat` flag to skip chat bridge installation
- `--chat <bridge>` flag for pluggable chat interfaces (default: Kimaki for Discord)
- `--dry-run` flag for testing
- `--root` flag to run agent as root
- Multisite detection for existing installs (per-site agent file path resolution)
- AGENTS.md template with `{{SITE_PATH}}` placeholder
- BOOTSTRAP.md for first-run agent instructions
- Kimaki systemd service configuration
- OpenCode JSON config generation with DM memory file injection