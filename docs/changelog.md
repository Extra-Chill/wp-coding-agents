# Changelog

## [0.7.0] - 2026-04-26

### Changed
- collapse chat bridges into auto-discovered bridges/*.sh files

## [0.6.4] - 2026-04-26

### Changed
- trim upgrade-wp-coding-agents to policy + procedure

## [0.6.3] - 2026-04-26

### Fixed
- prepend node bin dir on launchd PATH for nvm installs
- point AGENTS.md regeneration at `datamachine memory compose`

## [0.6.2] - 2026-04-26

### Fixed
- restore opencode plugins (dm-context-filter, dm-agent-sync) after npm update (#71)
- make dm-context-filter stripSection fence-aware so fenced bash comments stop being treated as headings (#72)
- install security-policy plugins on every setup/upgrade, not just fresh (#67)
- resolve Data Machine memory paths in Studio (#69)
- refresh kimaki service PATHs (#70)

### Added
- effective-prompt regression test harness with pluggable args/filters/triggers, wired into upgrade.sh (#72)

## [0.6.1] - 2026-04-25

### Fixed
- include node bin dir in launchd PATH
- migrate agent.build.prompt to instructions array

## [0.6.0] - 2026-04-23

### Added
- populate every detected runtime's skills dir

### Fixed
- restore wp-coding-agents skills on every kimaki restart
- fix(dm-context-filter): strip project discovery from system prompt

## [0.5.0] - 2026-04-22

### Added
- feat(dm-agent-sync): recompose AGENTS.md at session start
- install in-repo skills and silence workspace prompts

### Changed
- make Data Machine mandatory, drop --no-data-machine

### Fixed
- use instructions array, not agent.build.prompt

## [0.4.2] - 2026-04-21

### Changed
- refactor(chat-bridges): centralize metadata + unit templates into lib/chat-bridges.sh

## [0.4.1] - 2026-04-20

### Fixed
- skip claude-auth on kimaki + upgrade.sh repair path for existing installs
- run detect_environment before chat-bridge detection (closes #54)
- add cc-connect + telegram chat-bridge support (closes #48)
- make upgrade.sh + skill env-agnostic for local installs

## [0.4.0] - 2026-04-19

### Added
- add upgrade.sh for safe VPS upgrades

### Fixed
- use in-place compose for AGENTS.md

## [0.3.0] - 2026-04-18

### Added
- add launchd service for Kimaki on macOS
- add multi-agent support via dm-agent-sync plugin

### Changed
- Patch opencode-claude-auth to use PascalCase mcp_ tool names
- Add --runtime-only flag to skip infrastructure phases
- Replace python3 with jq for settings.json merge and fix hook format
- delegate AGENTS.md generation to SectionRegistry compose
- Improve AGENTS.md: add abilities, expand Data Machine, drop stale sections
- Add Studio Code runtime support
- Remove BOOTSTRAP.md — setup skills handle first-run
- Use gh repo clone for GitHub URLs in install_plugin
- Add DM workspace to Claude Code additionalDirectories
- Rename launchd service prefix from com.extrachill to com.wp
- Install composer/npm deps for pre-cloned plugins
- Decouple agent display name from slug in SOUL.md and setup
- Add agent naming question to setup skill
- Add credential sync wrapper for opencode-claude-auth + Kimaki
- Unify AGENTS.md as single source of truth for agent instructions
- Add opencode-claude-auth to OpenCode runtime for Claude Max/Pro OAuth
- Use --content flag for agent file writes, add SessionStart hook for DM sync
- Modularize setup.sh, add runtime auto-discovery, merge Claude Code
- Build JS assets in install_plugin, add macOS launchd for Telegram
- Update setup skill: add Telegram, WP_CMD, dry-run, local verification
- Add EXTRA_PLUGINS, MCP_SERVERS, and WP_CMD env var support
- Move platform detection before root check
- Set DATAMACHINE_WORKSPACE_PATH in wp-config.php during setup
- Use platform-aware workspace path for Data Machine Code
- Remove RunAtLoad from Kimaki launchd plist
- lean down AGENTS.md template (93 → 33 lines)

### Fixed
- fix(kimaki-plugin): strip worktree conflicts + low-value sections from agent context
- Fix Studio Code runtime writing invalid SessionStart hook format
- Fix Studio Code runtime to detect dev CLI
- Fix dm-agent-sync hook: detect dev CLI, handle inline JSON summary
- Fix install_plugin gh clone failing on macOS due to .git suffix
- Fix README: accurately describe the memory system
- Fix README: DM creates two files on activation, not three
- Fix OpenCode plugin paths for local mode
- Fix Kimaki launchd: only start service when bot token is provided
- Fix opencode.json prompt strings to use escaped newlines
- Fix JSON extraction from wp datamachine agent paths on SQLite
- Fix KIMAKI_DATA_DIR for local mode

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
