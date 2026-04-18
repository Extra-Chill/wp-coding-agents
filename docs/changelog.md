# Changelog

## [Unreleased]

### Fixed
- Kimaki plugin: strip `--worktree` / `--cwd` examples and the per-turn "## worktree" block from the agent context. Data Machine Code owns the workspace and creates its own worktrees; leaving Kimaki's worktree language in the prompt caused the agent to try running work inside a Kimaki worktree instead of the DM Code workspace.

## [0.2.1] - 2026-04-07

### Changed
- Remove reference to private repo from README
- Update README for local/macOS support and new architecture
- Extract helper functions to reduce repetition
- Add --local flag for macOS and local WordPress installs
- Install data-machine-code alongside Data Machine core
- Document Telegram bridge support in README — matches setup.sh capabilities
- Add Abilities API section to README — connect Data Machine to WordPress core

## [0.2.0] - 2026-04-04

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
- `wp-coding-agents-setup` skill for local agents assisting with installation
- `README.md`, `LICENSE` (MIT), `VERSION`
- `docs/changelog.md`
- use 'wp datamachine agent paths' for file discovery instead of hardcoded paths
- add Telegram bridge support via --chat telegram
- add skills, README, LICENSE, VERSION, and --no-skills flag
- add --multisite/--subdomain flags and docs/changelog

### Changed
- Register as Homeboy component with version pattern
- Allow Data Machine workspace as external_directory in opencode.json
- AGENTS.md: grep examples point to full WP install (plugins, themes, core)
- AGENTS.md: grep tip applies to all plugins/themes, not just DM
- AGENTS.md: discovery-first CLI guidance
- Clone DM skill from data-machine-skills repo instead of bundling
- Merge kimaki-config into wp-coding-agents
- Default to root user, add --non-root flag
- Remove hardcoded model defaults, let OpenCode use zen free models
- Add USER.md injection, multisite support, small_model
- Initial scaffolding: setup.sh, AGENTS.md template, BOOTSTRAP.md

### Fixed
- Fix Why Root section: acknowledge multi-agent VPSes
- Fix skills discovery with Kimaki and make phases idempotent for safe re-runs
- Fix skills discovery: use .opencode/skills/ path, add --skills-only flag
- Fix OpenCode install: use official install script instead of npm
- create service user before Phase 4 chown

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
