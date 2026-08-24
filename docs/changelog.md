# Changelog

## [1.19.2] - 2026-08-24

### Fixed
- resolve DMC worktree from scoped inventory

## [1.19.1] - 2026-08-24

### Fixed
- embed local subagent graph sources
- discover DMC workspace before Homeboy config

## [1.19.0] - 2026-08-24

### Added
- manage copied DMC releases

### Changed
- defer Data Machine memory composition
- stabilize DMC integration path assertion
- execute colocated subagent reader payload

### Fixed
- allow bounded DMC worktree planning
- scope DMC worktree inventory by repository
- verify DMC release asset digests
- preserve DMC tracker evidence in resolve
- classify OpenCode projection failures
- resolve DMC provider from source contract
- preserve upgrade recovery summaries
- bootstrap colocated OpenCode subagent graph
- plan DMC worktrees for Homeboy
- expose DMC provider convergence

## [1.18.1] - 2026-08-22

### Fixed
- evaluate bounded log policies frequently
- bound unreadable proc descriptor evidence
- probe standalone DMC provider readiness

## [1.18.0] - 2026-08-22

### Added
- provision managed VPS capabilities

### Changed
- drop the opencode-claude-auth wrapper strip, keep the decision pinned

### Fixed
- pass Homeboy lifecycle to DMC ensure
- use standalone DMC worktree provider
- retry external WordPress transport
- preserve external context records

## [1.17.0] - 2026-08-21

### Added
- separate gateway model identity
- project subagents into external runtimes
- support portable external WordPress runtimes
- project Agents API subagents for OpenCode

### Changed
- repair degenerate snapshots and refuse to record them
- Scope inbound claims by runtime
- Add external inbound event delivery
- Add durable inbound event bridge

### Fixed
- seed external Kimaki credentials
- avoid hanging Kimaki version probe
- retry stalled external graph reads
- bound external subagent graph reads
- skip PHP package detection with dependencies
- use native OpenAI gateway provider
- tolerate Kimaki lookup startup latency
- order external WordPress global flags
- use OpenCode environment interpolation
- serialize empty subagent maps
- configure gateway for external runtimes
- bound CLI dispatch process trees
- Fix canonical OpenCode workspace permissions
- bridge Kimaki session attribution

## [1.16.3] - 2026-08-07

### Fixed
- make scaffold-to-editable actually work, three bugs deep

## [1.16.2] - 2026-08-07

### Fixed
- an hour is not a latency, it is a wall

## [1.16.1] - 2026-08-07

### Fixed
- a crashed prompt test is not a leaking prompt filter

## [1.16.0] - 2026-08-07

### Added
- assert the cross-layer invariants with verify.sh

## [1.15.0] - 2026-08-06

### Added
- reconcile the owned source set continuously, not at upgrade time

## [1.14.0] - 2026-08-06

### Added
- derive the owned source set from site state

### Fixed
- the unit's environment must follow the service identity
- redact CLI transport diagnostics

## [1.13.1] - 2026-08-05

### Fixed
- reconcile the manifest and migrate the sibling option keys

## [1.13.0] - 2026-08-05

### Added
- project the declared owned sources to a readable manifest

## [1.12.0] - 2026-08-05

### Added
- owned mode defaults to a non-root service user
- migrate an installed root agent onto a non-root service user
- guard the agent runtime against admin-UI deactivation on managed installs

### Changed
- rename posture to source mode (workspace | owned)

### Fixed
- run the whole test suite in CI, and repair the break it was hiding
- use environment for Kimaki lock port

## [1.11.4] - 2026-08-03

### Fixed
- reconcile external_directory and pass all declarations to the reconciler

## [1.11.3] - 2026-08-03

### Fixed
- grant log paths as both literal and subtree

## [1.11.2] - 2026-08-03

### Changed
- Restore the wordpress-source section's purpose; close the wp-admin/wp-config/mu-plugins gaps

## [1.11.1] - 2026-08-03

### Fixed
- scope managed posture to declared owned sources
- set KIMAKI_NO_DEFAULT_CHANNEL on managed Kimaki services

## [1.11.0] - 2026-08-02

### Added
- support a managed-hosting posture

## [1.10.7] - 2026-07-29

### Fixed
- configure targeted DMC path resolution
- provision DMC Cook worktree destinations

## [1.10.6] - 2026-07-27

### Fixed
- isolate agent sync from login profiles
- deduplicate managed runtime skills
- detect stale Kimaki dispatch helpers
- stop provisioning exposing wp-config.php

## [1.10.5] - 2026-07-24

### Fixed
- remove Homeboy notification command shim

## [1.10.4] - 2026-07-24

### Changed
- Refine generated agent routing guidance

### Fixed
- Fix effective prompt contract drift

## [1.10.3] - 2026-07-23

### Fixed
- migrate legacy Claude edit denies

## [1.10.2] - 2026-07-23

### Fixed
- anchor Claude WordPress edit denies

## [1.10.1] - 2026-07-23

### Changed
- Own generic WordPress agent guidance and runtime permissions

## [1.10.0] - 2026-07-22

### Added
- Bridge Kimaki context to Homeboy notifications: map validated Kimaki thread/channel snowflakes to a generic Homeboy notification route (`HOMEBOY_NOTIFICATION_ROUTE`) at the OpenCode-to-wrapper boundary, with concurrent-thread isolation, so a cook reports run completion back to its originating Discord thread without hardcoding launcher assumptions in Homeboy core ([#261](https://github.com/Extra-Chill/wp-coding-agents/pull/261)) (by Chris Huber)

## [1.9.8] - 2026-07-22

### Changed
- Invalidate cached Homeboy guidance on upgrades ([#289](https://github.com/Extra-Chill/wp-coding-agents/pull/289)) (by Chris Huber)

## [1.9.7] - 2026-07-21

### Changed
- Generate live Homeboy configuration pointers in AGENTS.md ([#287](https://github.com/Extra-Chill/wp-coding-agents/pull/287)) (by Chris Huber)

## [1.9.6] - 2026-07-16

### Fixed
- support evolving Kimaki prompt signatures

## [1.9.5] - 2026-07-13

### Fixed
- make non-root upgrades idempotent

## [1.9.4] - 2026-07-13

### Fixed
- back up Kimaki config in writable state

## [1.9.3] - 2026-07-13

### Fixed
- preserve web directory permissions during sync

## [1.9.2] - 2026-07-13

### Fixed
- omit directory times during carried sync

## [1.9.1] - 2026-07-13

### Fixed
- support non-root carried plugin sync

## [1.9.0] - 2026-07-13

### Added
- support multiple service instances
- configure targeted DMC worktree resolution
- add Data Machine worker heartbeat (#262)

### Changed
- register runtime context projections
- Install worker heartbeat during upgrades

### Fixed
- drive cron from worker heartbeat (#270)
- resolve Studio CLI for Data Machine worker (#267)
- map DMC worktree safety output for Homeboy
- normalize ownership + group-write on service files written into the web tree
- enumerate homeboy CLI command map live at AGENTS.md compose time (#254)

## [1.8.6] - 2026-07-05

### Fixed
- prune AGENTS.md upgrade backups

## [1.8.5] - 2026-07-05

### Fixed
- allow non-root upgrade identity adoption

## [1.8.4] - 2026-07-03

### Fixed
- sync OpenCode auth state on account rotation

## [1.8.3] - 2026-07-03

### Fixed
- refresh Anthropic OAuth after auth failures

## [1.8.2] - 2026-07-03

### Fixed
- sync OpenCode auth plugin during upgrade

## [1.8.1] - 2026-07-03

### Fixed
- harden OpenCode Anthropic OAuth refresh

## [1.8.0] - 2026-07-02

### Added
- add OpenCode Claude Code auth

## [1.7.0] - 2026-07-02

### Added
- add Codex as a supported runtime with generated AGENTS.override.md loading, project-local skills, runtime attribution, and a managed Data Machine memory mirror
- add Codex runtime support

## [1.6.2] - 2026-06-30

### Fixed
- support macOS bash in Homeboy provider config

## [1.6.1] - 2026-06-30

### Changed
- Clarify Homeboy AGENTS orchestration map

## [1.6.0] - 2026-06-30

### Added
- configure homeboy DMC worktree provider

### Fixed
- make upgrade cover the Claude Code runtime + single-agent scoping

## [1.5.4] - 2026-06-26

### Fixed
- grant kimaki dispatch to service user

## [1.5.3] - 2026-06-21

### Fixed
- run scheduled Kimaki dispatch as the adopted service user

## [1.5.2] - 2026-06-18

### Fixed
- pin writable HOME for CLI dispatch so scheduled kimaki sends survive WP-cron

## [1.5.1] - 2026-06-16

### Changed
- gate homeboy AGENTS guidance fixture

### Fixed
- gate generated AGENTS guidance

## [1.5.0] - 2026-06-15

### Added
- write DATAMACHINE_COMPOSE_AGENTS_MD gate to wp-config on setup/upgrade

### Changed
- Add opt-in WP AI Gateway setup for OpenCode
- Revert "fix kimaki dm memory prompt injection"

### Fixed
- fix opencode dm instruction repair
- fix kimaki dm memory prompt injection
- fix kimaki instruction prompt leaks

## [1.4.9] - 2026-06-15

### Fixed
- resolve kimaki binary against adopted service identity, not invoking shell

## [1.4.8] - 2026-06-15

### Fixed
- fix kimaki managed system prompt patch

## [1.4.7] - 2026-06-15

### Changed
- test kimaki managed runtime freshness

### Fixed
- fix kimaki final system prompt stripping
- fix kimaki datamachine command context
- fix kimaki launchd stale opencode cleanup

## [1.4.6] - 2026-06-14

### Fixed
- fix homeboy project resolution by site path

## [1.4.5] - 2026-06-14

### Fixed
- fix homeboy component attach status handling

## [1.4.4] - 2026-06-14

### Fixed
- Fix managed Kimaki prompt replacement and skill surface enforcement.

## [1.4.3] - 2026-06-14

### Changed
- Internal improvements

## [1.4.2] - 2026-06-13

### Changed
- assert live managed runtime state

### Fixed
- refresh managed upgrade skill
- tolerate partial component pruning
- prune stale worktree components
- fix upgrade homeboy service user context

## [1.4.1] - 2026-06-13

### Changed
- clarify managed prompt replacement invariant

### Fixed
- keep managed prompt conditional
- replace managed system prompt
- strip stale orchestration guidance

## [1.4.0] - 2026-06-13

### Added
- feat(agents-md): generate presence-gated homeboy CLI section from homeboy --help (#208)

## [1.3.1] - 2026-06-13

### Changed
- Restore generated changelog
- Remove unsupported Studio Code runtime
- Remove unrelated prompt snapshot refresh
- Remove manual changelog entry
- Add Kimaki managed plugin rig

### Fixed
- Fix Homeboy release packaging config
- adopt service identity from existing unit instead of assuming root

## [1.3.0] - 2026-06-12

### Added
- make wp-coding-agents skills opt-in
- derive opencode instructions from Data Machine injectable memory files
- keep WP Codebox current via subtree-aware plugin updates

### Changed
- Own CLI dispatch transport in wp-coding-agents
- Encode empty tool_use input as a JSON object
- Add structured tool calling to Claude Code provider
- add claude-opus-4-8 model to Claude Code provider
- replace Claude Code CLI provider with OAuth API
- add Claude Code provider plugin
- clarify upgrade skill boundary
- add Homeboy Codebox canary verification
- clarify agents guidance sync API

### Fixed
- allowlist managed skills
- disable critique skill in managed services
- register a web-traversable kimaki binary for CLI dispatch (#198)
- fix Claude Code provider Codebox canary
- install only upgrade skill by default
- preserve Homeboy project detection for blank site URLs
- add AGENTS.md section provenance metadata
- tighten Kimaki prompt hint filtering
- scope agent task guidance to available tooling
- cover compiler edge cases
- preserve home path expansion in compiler
- publish codebox agent task guidance

## [1.2.2] - 2026-05-30

### Fixed
- resolve eslint findings in dm-agent-sync plugin
- single-source homeboy_project_id and resolve real registered id
- report attach-path results truthfully and resolve project id consistently
- normalize HOME paths in effective-prompt snapshots

## [1.2.1] - 2026-05-28

### Fixed
- Removed stale Kimaki skill names from the managed disable list so Kimaki 0.13
  startup does not warn about non-bundled skills.

## [1.2.0] - 2026-05-28

### Changed
- Kimaki bridge now registers native `kimaki` for CLI-channel dispatch and
  relies on Kimaki 0.13's unavailable-agent fallback to the default/build
  agent instead of shipping a Data Machine command adapter.
- Kimaki bridge now uses native `kimaki send --cwd` routing instead of the
  `datamachine-kimaki-session` handoff helper.
- Kimaki upgrade/config sync now uses Kimaki 0.13 native skill filters via
  `--disable-skill` instead of deleting package-owned skill directories.
- `dm-agent-sync` now only recomposes Data Machine memory and no longer mutates
  OpenCode agent prompt slots.
- `dm-context-filter` keeps generic Kimaki `--agent <current_agent>` guidance
  when it survives the existing section-level filters; the old inline stripping
  only existed to compensate for pre-0.13 missing-agent behavior.
- Runtime-signature registration now records only observed env vars: OpenCode's
  `OPENCODE_RUN_ID`; Kimaki signature blocks from older releases are removed
  until Kimaki exports stable session/thread attribution env vars.

### Removed
- Removed the `datamachine-kimaki` send-argument adapter and upgrade-time
  command shim installation. Upgrade now deletes prior wp-coding-agents-owned
  adapter files when their marker proves they came from this package.
- Removed the `datamachine-kimaki-session` helper and its smoke test.

## [1.1.0] - 2026-05-17

### Added
- register kimaki + opencode worktree runtime signatures

## [1.0.0] - 2026-05-16

### Added
- Outbound chat-bridge dispatch via `agents/dispatch-message` (#130). Each
  chat bridge (`kimaki`, `cc-connect`, `telegram`) now writes a marker-
  delimited block to `wp-content/mu-plugins/wp-coding-agents-channels.php`
  during install and on every upgrade, registering a channel → command +
  argv template entry consumed by Data Machine Code's generic CLI transport
  runtime (Extra-Chill/data-machine-code#412, shipped in DMC v0.44.0). With
  this in place a Data Machine flow can call `agents/dispatch-message` with
  `channel='kimaki'` (or `cc-connect`, or `telegram`) and the runtime shells
  the configured command — no HTTP webhook, no nginx hop, no sidecar process.
- `lib/cli-channel.sh`: idempotent mu-plugin registrar with per-bridge block
  markers, atomic rewrite, optional dry-run, and shell-safe substitution of
  `{recipient}`, `{message}`, `{conversation_id}`, `{channel}`.
- README section "Outbound Dispatch" documents the integration model, what
  `recipient` means per bridge, and the manual migration runbook for retiring
  any legacy ad-hoc agent-ping webhooks.

### Changed
- `bridges/kimaki.sh`, `bridges/cc-connect.sh`, `bridges/telegram.sh` each
  call their respective `_<name>_register_cli_channel` at install time and
  on `bridge_sync_config` (upgrade-time), so the resolved command path and
  any captured credentials stay fresh across npm-global moves and rotations.
- `setup.sh` and `upgrade.sh` load the new `lib/cli-channel.sh` module.
- Kimaki bridge: adapt `kimaki send` flag handling for Data Machine compat
  (#121), allow native worktree routing through dm-context-filter (#128),
  make the context filter strip-only (#119), prefer the command shim in
  launchd sessions (#122), point opencode plugin paths at persistent
  config (#124), use durable local plugin paths (#123), stop installing
  redundant external skills (#127), and clarify agent slot normalization
  in dm-context-filter docs (#3f40caf).

### Earlier (originally drafted as 0.9.0 on 2026-05-04, never tagged)

### Removed
- BREAKING: drop all `opencode-claude-auth` integration (#117). The bash
  wrapper at the global `opencode` binary, the PascalCase patch, the
  third-party plugin entry in generated `opencode.json`, and the matching
  drift check in `lib/repair-opencode-json.py` are gone. Kimaki's built-in
  AnthropicAuthPlugin handles OAuth on Kimaki bridges; non-Kimaki bridges
  use opencode's native auth flow (`opencode auth login anthropic`). Older
  upgrades installed the wrapper unconditionally on every Kimaki VPS, which
  shimmed the npm-shipped binary purely to feed a plugin we no longer load.
- delete `lib/patch-claude-auth.py` and `tests/opencode-wrapper.sh`.

### Added
- `_remove_legacy_opencode_wrapper` in `runtimes/opencode.sh`. Detects the
  `wp-coding-agents-opencode-wrapper-v2` sentinel on the global `opencode`
  binary, restores a hardlink (or symlink) to the real `.opencode` binary,
  and cleans up matching `.bak.*` files. Runs from `runtime_install` and
  from upgrade Phase 7. Idempotent and a no-op on installs that never had
  the wrapper.
- `tests/opencode-wrapper-removal.sh` regression: legacy wrapper is removed
  cleanly, repo no longer ships the install machinery, non-wrapper binaries
  are never touched.

### Changed
- upgrade Phase 7 renamed from `reapply_claude_auth_patch` to
  `remove_legacy_opencode_wrapper_phase`.
- `.github/workflows/shell.yml`: replace `opencode-wrapper` job with
  `opencode-wrapper-removal`.

## [0.8.2] - 2026-05-03

### Fixed
- satisfy agent sync lint
- preserve Data Machine context
- symlink CLAUDE.md → AGENTS.md for Claude-model opencode sessions
- refresh stale kimaki wrapper

## [0.8.1] - 2026-05-03

### Changed
- refresh systemd bridge snapshot

### Fixed
- satisfy plugin lint rules
- strip project routing guidance
- reap orphaned opencode-serve children on service start

## [0.8.0] - 2026-05-02

### Added
- register Homeboy project

### Fixed
- verify WordPress extension during setup
- attach DMC primaries as project components

## [0.7.5] - 2026-05-02

### Fixed
- add Data Machine session handoff

## [0.7.4] - 2026-04-30

### Fixed
- declare homeboy availability before compose
- add WordPress runtime guidance

## [0.7.3] - 2026-04-28

### Fixed
- retry-with-backoff git clones, force HTTPS for setup deps
- include user tool dirs in launchd PATH

## [0.7.2] - 2026-04-27

### Fixed
- warn when context filter plugins are missing
- fall back when data-dir sources are missing
- skip wp-env-based plugin builds when Docker is unavailable
- follow Data Machine memory CLI drift
- data-machine CLI drift breaks SessionStart hook + Phase 4.5 scaffold

## [0.7.1] - 2026-04-27

### Fixed
- strip agent override minion examples
- update Data Machine plugins by tag

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
