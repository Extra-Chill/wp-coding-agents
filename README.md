# WP Coding Agents

**Composable coding agents for WordPress-powered workspaces.**

`wp-coding-agents` turns a WordPress install into the home base for an AI coding agent. WordPress provides the durable operating layer, Data Machine composes the agent's memory and instructions, a coding runtime executes work, and optional bridges or orchestrators connect the agent to humans and lab environments.

The goal is a focused agent context: each installed component contributes the guidance it owns, and unavailable components stay out of the prompt.

OpenCode agents and their models remain operator-owned. Portable specialist
graphs install only through `--project-agent-bundle <slug>`; selecting a
WordPress agent for context does not project its chat model into native
subagents. See [OpenCode agent ownership](docs/opencode-agent-ownership.md).

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
  ├─ Pi (through Roadie)
  └─ OpenCode
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
- **Coding runtimes** add only their runtime-specific configuration, such as OpenCode instructions. Other terminal tools (Codex, Claude Code, Pi) read the composed `AGENTS.md` directly.
- **Chat bridges** describe the human communication surface when that bridge is selected.
- **Developer orchestration layers** add guidance only when installed and verified.
- **Unavailable tools** do not get stub instructions, fallback recipes, or negative constraints.

For example, a Roadie install should know Roadie is the Discord surface. It should not learn generic Roadie worktree, tunnel, or session-fanout recipes when those responsibilities belong to other installed components. Likewise, Homeboy guidance appears only when Homeboy is available. wp-coding-agents policy declares repository authority; the selected coding runtime uses its native file, Git, and GitHub tools; Homeboy owns its native Rust worktree lifecycle and Cook.

## What It Enables

### Local Agent

Run an agent from an existing local WordPress site and keep its context grounded in that site.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local
cd ~/Studio/my-site && opencode
```

Any terminal coding tool that reads `AGENTS.md` (Pi, Codex, Claude Code via the `CLAUDE.md` symlink) gets the same site context when started from the site root. wp-coding-agents does not install or configure those tools.

### Chat-Connected Agent

Connect the coding runtime to a human chat surface for planning, status, file uploads, and review loops.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --chat roadie
cd ~/Studio/my-site && roadie
```

### Always-On VPS Agent

Install WordPress, Data Machine, the runtime, and a chat bridge on a dedicated server.

```bash
SITE_DOMAIN=example.com ./setup.sh
```

### Repo-Aware Developer Workflows

Declare each primary Git checkout with wp-coding-agents, then use the selected coding runtime's native file, Git, and GitHub tools there. Homeboy is optional orchestration for native Rust worktree lifecycle and Cook; it attaches declared checkouts and never infers repository authority.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --with-homeboy \
  --workspace-repository ~/Developer/my-site
```

When an optional orchestrator is available, its own presence-gated AGENTS section explains the supported workflow. When it is absent, the prompt does not mention its commands.

## Components

| Component | Role | Availability |
| --- | --- | --- |
| WordPress | Site runtime, plugin host, WP-CLI surface | Existing local install or installed on VPS |
| Data Machine | Agent identity, memory, composed guidance, abilities, flows, jobs | Always installed |
| OpenCode | Coding runtime | Selected or auto-detected |
| wp-coding-agents | Source policy, declared repository authority, runtime permissions, setup, and upgrade | Always installed |
| Roadie | Discord bridge running Pi agent sessions | Optional chat bridge (the only one) |
| Homeboy | Optional repo-aware task/lab orchestration, native Rust worktree lifecycle, and Cook | Enabled with `--with-homeboy` when available |

## Installation

### Local

Use an existing WordPress install.

```bash
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents

EXISTING_WP=~/Studio/my-site ./setup.sh --local
```

OpenCode is the only managed runtime, so `--runtime opencode` is the default. The Codex and Claude Code runtimes were removed ([#751](https://github.com/Extra-Chill/wp-coding-agents/issues/751)): `--runtime codex|claude-code`, or an installation profile that recorded either one, fails with a migration note. Use Pi with Roadie, or run those tools in a terminal against the composed `AGENTS.md`.

### VPS

Run setup from the server.

```bash
git clone https://github.com/Extra-Chill/wp-coding-agents.git
cd wp-coding-agents

SITE_DOMAIN=example.com ./setup.sh
```

### Optional Data Machine Worker

Setup and upgrades leave the managed Data Machine worker disabled by default.
Interactive CLI operations continue to work without it. Install the worker only
when the site should drain Data Machine work while no operator or web request is
present:

```bash
./setup.sh --with-datamachine-worker
```

The choice persists across upgrades. Disable it and remove the managed launchd
or systemd service with `./upgrade.sh --no-datamachine-worker`. The worker runs
one bounded `wp datamachine worker run --once` pass every two minutes; it does
not execute generic due WP-Cron events.

### Optional Local WordPress Service

On macOS, an existing site can run without a separate local development app by
using WP-CLI's built-in HTTP server under launchd:

```bash
EXISTING_WP=/path/to/wordpress ./setup.sh --local \
  --with-wordpress-service --wordpress-service-port 8080
```

The service binds to `127.0.0.1` by default, is identified by the site's absolute
path, and remains enabled across upgrades. It requires a direct `wp` transport.
It runs 4 PHP workers by default (`PHP_CLI_SERVER_WORKERS`), so a slow request,
such as a loopback Action Scheduler runner doing remote work, does not block
page loads. Change it with `--wordpress-service-workers <n>`; the value persists
across upgrades.

Disable it with:

```bash
./upgrade.sh --local --wp-path /path/to/wordpress --no-wordpress-service
```

### External WordPress Runtime

Run the coding runtime on a host without a mounted WordPress tree. The control
transport is a JSON argv array so paths and arguments are preserved without
shell parsing. It is runtime input only; setup never writes it into generated
files. Keep credentials out of argv: the transport executable should resolve
them from its process environment or credential store.

```bash
RUNTIME_PROJECT_ROOT=/srv/agent \
WP_CONTROL_TRANSPORT_JSON='["/usr/local/bin/wp-control","--target","site-a"]' \
./setup.sh --external-wordpress --wordpress-path '/srv/wordpress site' \
  --wordpress-user agent --runtime opencode --chat roadie
```

Setup validates `core is-installed` through the transport, then projects Data
Machine injectable files below `$RUNTIME_PROJECT_ROOT/.wp-coding-agents/context`.
OpenCode, Roadie state, skills, `AGENTS.md`, and `CLAUDE.md` stay below the
runtime root. The transport must provide WordPress commands and must not be
stored in project files.

Start Roadie from the same runtime environment so the generated
`.wp-coding-agents/bin/wp-control` wrapper can read the transport variables.
External profiles deliberately avoid writing those variables to launchd or
systemd units. Re-run setup to refresh projected Data Machine context.

External setup also installs `.wp-coding-agents/bin/inbound-event-connector`.
It continuously polls the durable inbound queue through `wp-control`, delivers
supported events locally, and acknowledges only after a successful local HTTP
response. It is disabled until its Slack delivery contract is explicitly set in
the runtime environment:

```bash
WP_CODING_AGENTS_INBOUND_SLACK_ENABLED=1 \
WP_CODING_AGENTS_RUNTIME_ID='runtime-opaque-1' \
WP_CODING_AGENTS_INBOUND_SLACK_ENDPOINT='http://127.0.0.1:3710/slack/events' \
WP_CODING_AGENTS_INBOUND_SLACK_SIGNING_SECRET_ENV=LOCAL_SLACK_SIGNING_SECRET \
LOCAL_SLACK_SIGNING_SECRET='...' \
/srv/agent/.wp-coding-agents/bin/inbound-event-connector
```

The endpoint must be an `http` or `https` literal loopback IP URL. When explicitly
enabled, the endpoint defaults to `http://127.0.0.1:3710/slack/events`.
The signing-secret variable name is explicit so secrets remain in the process
environment, never generated files or command arguments. Slack ingress persists
only verified `team_id`, `channel_id`, `actor_id`, `message_ts`, and root
`thread_ts`; it does not persist request signatures, secrets, tokens, or raw
payloads. Queue adapters can add bounded scalar-string `attributes` without
changing the generic queue envelope.
`WP_CODING_AGENTS_RUNTIME_ID` is required and must match the runtime ID in the
queued envelope; the connector includes it in every queue poll so runtimes only
lease their own events.

```bash
WP_CONTROL_TRANSPORT_JSON='["/usr/local/bin/wp-control","--target","site-a"]' \
  /srv/agent/.wp-coding-agents/bin/roadie
```

The setup profile compiler emits this credential-bearing start command
separately from the one-shot setup command. The first portable profile supports
OpenCode; select `runtime.selection=opencode` explicitly.

Add `--with-ai-gateway` to generate the credential-free
`wp-ai-gateway/site-default` OpenCode provider. External mode does not install
gateway plugins, configure a route, mint a token, or write an env file. Supply
`OPENAI_BASE_URL` and `OPENAI_API_KEY` in the runtime environment when starting
Roadie.

Use the same transport input when validating an external profile. `verify.sh`
continues to validate colocated WordPress installs; external runtime validation
is the transport's `core is-installed` check performed by setup plus inspection
of the runtime-local config and projected context.

For agent-assisted setup, give your local coding agent the setup entrypoint:

```text
operator-entrypoints/wp-coding-agents-setup/setup.md
```

## Common Setup Options

| Flag | Description |
| --- | --- |
| `--runtime <name>` | Coding runtime: `opencode` (the default and only value). `codex` and `claude-code` were removed in #751. |
| `--source-mode <name>` | `workspace` (default) or `owned`. See [Source Mode](#source-mode). `--posture` is a deprecated alias. |
| `--workspace-repository <absolute-git-checkout>` | Existing primary Git checkout authority for workspace mode. Repeatable. |
| `--workspace-repository-clone <git-remote> <absolute-destination>` | Materialize and declare a missing primary checkout. Existing destinations are validated and never overwritten; credential-free declarations persist for upgrade recovery. Repeatable. |
| `--owned-source <path>` | wp-content path the site owns and may edit under `--source-mode owned`. Repeatable. |
| `--owned-writable <path>` | Denied path to re-open for editing (e.g. `wp-config.php`). Not captured. Repeatable. `wp-config.php` may be opted in with either source mode; it is made group-writable for `www-data`. |
| `--log-path <path>` | Absolute path outside the site root the agent may read. Repeatable. |
| `--local` | Local machine mode. Skips server infrastructure. |
| `--existing` | Add to an existing WordPress install. |
| `--wp-path <path>` | WordPress root path. Implies `--existing`. |
| `--agent-slug <slug>` | Override the Data Machine agent slug used by runtime instruction projections. Persisted for subsequent upgrades. |
| `--roadie-unit <unit>` | Target a Roadie systemd instance, such as `roadie-example.service`. |
| `--roadie-data-dir <path>` | Override that Roadie instance's state directory. |
| `--roadie-lock-port <port>` | Override that Roadie instance's lock port. |
| `--chat <bridge>` | Chat bridge: `roadie` (the only bridge). |
| `--no-chat` | Skip chat bridge setup. |
| `--with-homeboy` | Enable optional Homeboy project/lab integration when available. |
| `--with-ai-gateway` | Enable optional [WP AI Gateway](https://github.com/Automattic/wp-ai-gateway) setup for Pi (Roadie sessions); an existing `opencode.json` gains the same provider. Without it, Pi stays on Roadie's credential pool. |
| `--ai-gateway-provider <id>` | WordPress AI Client backend provider for the gateway route (default: `openai`). |
| `--ai-gateway-model <id>` | Backend model for the gateway route (default: `gpt-4o-mini`). |
| `--ai-gateway-opencode-model <id>` | OpenCode-facing gateway model ID (default: `site-default`). |
| `--rotate-ai-gateway-token` | Mint a replacement gateway token instead of reusing `.opencode/wp-ai-gateway.env`. |
| `--multisite` | Configure WordPress multisite. |
| `--subdomain` | Use subdomain multisite. |
| `--no-skills` | Accepted for compatibility; no agent skills are installed. |
| `--dry-run` | Print planned actions without applying them. |

Run `./setup.sh --help` for the complete setup surface.

## Source Mode

Source mode is where the agent's code changes land. It is a declared intent
rather than a detected fact, and it is the single input that decides the plugin
set, every runtime permission surface, and the AGENTS.md guidance the agent
reads.

These are two shapes, not two levels. Neither is "more access" than the other —
`workspace` is in fact *stricter* on live source, since the installed tree is
read-only reference there. What it buys is git and review, not latitude.

| | `workspace` (default) | `owned` |
| --- | --- | --- |
| WordPress core (`wp-admin/`, `wp-includes/`, root bootstrap) | read-only | read-only |
| `wp-content/mu-plugins/`, `wp-config.php` | read-only | read-only, opt-in |
| `wp-content/plugins/`, `wp-content/themes/` | read-only | read-only **except declared owned paths** |
| `wp-content/uploads/` | writable (agent memory) | writable (agent memory) |
| Repository authority | explicit primary Git checkout roots | none |
| Workspace, git, GitHub | wp-coding-agents policy plus the runtime's native tools | not present |
| How changes reach version control | the agent commits and opens pull requests | captured out-of-band by the operator |
| Runtimes | all | `opencode` only |
| Service user | root by default | **non-root by default** (`opencode`) |

### The owned set is derived, not declared

Ownership is a fact already on the box, not a judgement, so it is computed
rather than configured:

```
owned = installed  −  known to wp.org  −  installed by wp-coding-agents
                   −  explicitly excluded
```

A plugin the agent creates is therefore editable and captured with no operator
step and no self-declaration. `--owned-source` still overrides when supplied.

Derivation is **continuous**, not upgrade-time. An mu-plugin reconciles the
owned set, the capture manifest, and the runtime edit permissions as the
installed set changes:

- WordPress plugin and theme lifecycle hooks
- WP-CLI `after_invoke`, which fires in the *same command* that scaffolded a
  plugin — no race, no perceptible latency
- every bootstrap, so a directory created by any means (a bare `mkdir` from the
  agent's shell) is picked up by the next request
- an hourly sweep as a backstop for a site nobody is touching

An inventory fingerprint makes the usual call a single option read: measured at
0.16 ms against a 191 ms page render.

The derivation lives in PHP because that is the only place a WordPress hook can
reach it; the installer delegates to the same code rather than keeping a second
copy that could drift.

**It cannot widen on missing evidence.** The wp.org signal is a transient; on a
fresh install, after a cache flush, or when wp.org is unreachable it is absent,
and treating absence as "nothing belongs to wp.org" would classify every plugin
as the site's — handing the agent write access to WooCommerce and any payment
gateway. So a signal that is missing, empty, or older than two days produces no
derivation at all and the last recorded set is kept. Ownership is inferred only
from the presence of evidence.

`--not-owned <slug>` is the escape hatch for a premium or vendor plugin, which
is on nobody's wp.org list and is not carried by wp-coding-agents, yet is no
more the site's than WooCommerce is. Editing it is futile and capturing it may
put licensed code in the operator's repository.

### How out-of-band capture learns the editable set

Owned mode rests on one invariant: **the editable set equals the set the
operator's capture records.** A path the agent may edit but nothing captures is
where work silently disappears, and on a live site that stays invisible until an
update overwrites it.

Capture cannot read the `wp_coding_agents_owned_sources` option that holds the
editable set. It runs as a deliberately read-only identity that cannot read
`wp-config.php` — wp-coding-agents hardens that file to `www-data:640` itself —
so it can never run WP-CLI and never reach the database.

So owned installs project the declaration to a plain file:

```
/var/lib/wp-coding-agents/<domain>/owned-sources
```

One wp-content-relative path per line, mode `0644`, rewritten on every upgrade,
removed if the install leaves owned mode. It lives outside the site root because
`SITE_PATH` is the web root and a file written there is fetchable over HTTP.

A capture mechanism reads that file and derives its component list from it,
rather than keeping a second hand-maintained copy that can drift.

### The service user is the boundary that holds

The edit rules above are a guardrail, not containment. `permission.edit` gates
the runtime's edit tool; `bash` is a separate permission key, unset and
therefore allowed. A service running as root reaches every denied path through
`bash -c`, `wp eval`, or a PHP one-liner regardless of what the edit rules say.

So owned installs default to a dedicated non-root service user. That one is
enforced by the kernel rather than a config file: a non-root agent cannot
`apt install`, cannot rewrite a systemd unit, cannot read another site's
credentials, and cannot write `wp-admin/` whichever tool it reaches for.

Workspace installs keep the root default — that box belongs to a developer who
chose it. Existing installs of either mode are never flipped implicitly, since
that would strand the agent's state in the old home; migrate deliberately with
`sudo ./upgrade.sh --migrate-non-root`, which moves the agent's runtime state
across and leaves SSH keys and secret stores behind in root-owned `/root`.

Both modes point the agent at the installed WordPress source as reference —
that is the section's purpose, and it is why a small model can be competent
about WordPress here without skills or fine-tuning. Reading is never
restricted. Everything below is about *writing*.

**Workspace** is the developer setup: the installed tree is reference
material, and every code change happens in explicitly declared primary Git
checkouts so it is tracked in Git and reviewed through GitHub. wp-coding-agents
owns that declaration and runtime policy; the selected coding runtime uses its
native tools. When enabled, Homeboy owns its native Rust worktree lifecycle and
Cook without creating or inferring repository authority.

**Owned** is for managed agentic hosting, where a non-technical owner should
never have to deal with pull requests. The agent edits the site's own theme and
plugins directly and its changes are live on save; something outside the box —
for example a scheduled `homeboy harvest` — captures them into git as restore
points.

Managed does **not** open `wp-content`. Those directories hold third-party
code, the stock themes, and the agent's own runtime, none of which the site
owns or the operator's capture records. Declare exactly what the site owns:

```bash
./setup.sh --source-mode owned \
  --owned-source wp-content/themes/acme \
  --owned-source wp-content/plugins/acme-core
```

**The declared set must match what the operator's capture records** — a path
the agent can edit but nothing records is a path where it silently loses work.
Declaring nothing fails closed: no editable source, and the guidance says so.

### Declared exceptions

`wp-config.php` and `wp-content/mu-plugins/` are agent governance — they hold
the database credentials and the mu-plugin that generates AGENTS.md itself, so
an agent able to edit them can rewrite its own instructions. They are denied by
default and re-opened only on request:

```bash
./setup.sh --owned-writable wp-config.php
```

`wp-config.php` can be opted in with either source mode; the choice is recorded
for upgrades and re-applied during setup/upgrade. It receives
`www-data:www-data` ownership and mode `0660` only with this explicit opt-in;
otherwise it remains `0640`. `wp-content/mu-plugins/` remains read-only. These
exceptions are **editable but not captured**, and generated guidance says so
explicitly. Conflating them with `--owned-source` would have AGENTS.md promise
that the work is recorded when it is not.

### Log access

A coding agent that cannot read the PHP error log cannot recover the site it
just broke. OpenCode gates paths outside the site root behind
`external_directory`, which defaults to `ask` — and an autonomous agent has
nobody to ask. Declare the host's log paths so they are readable (never
writable):

```bash
--log-path /var/log/nginx --log-path /var/log/php8.4-fpm.log
```

A single source of truth (`lib/source-policy.sh`) derives the runtime
permissions and the generated guidance from the source mode and these
declarations, so the prose cannot tell the agent to do something the
permissions then block.

OpenCode evaluates permissions with `findLast` over rules in config key
order, so a narrow allow written after a broad deny wins.

The chosen mode is recorded on the install, so `./upgrade.sh` converges to it
without repeating the flag. Pass `--source-mode` to either script to change it.
Setup also records the resolved runtime and optional-component intent in
`.wp-coding-agents/installation-profile`. Upgrade loads that credential-free
profile before detection; explicit invocation values remain authoritative, and
tokens or command transports are never persisted there.

On VPS hosts with multiple Roadie services, setup and upgrade select the unit
whose `WorkingDirectory=` exactly matches the WordPress site path. Ambiguous or
unmatched installed units fail safely; pass `--roadie-unit` to select or create
an instance explicitly. The single-instance defaults are `roadie.service` and
`<service-home>/.roadie`.

## Runtime And Bridge Notes

### OpenCode

OpenCode uses `opencode.json` with Data Machine-composed instruction files. Roadie is the chat bridge for OpenCode when chat is enabled.

Pass `--with-ai-gateway` to opt the agent runtime into this site's [WP AI Gateway](https://github.com/Automattic/wp-ai-gateway) endpoint. Setup installs the gateway/provider stack, configures the backend route via WP-CLI, mints (or reuses) a gateway token, merges a `wp-ai-gateway` provider into Pi's `models.json` (pointing the Roadie unit's `ROADIE_PI_MODEL` at it), and writes an OpenAI-compatible `provider.wp-ai-gateway` entry into any existing `opencode.json`. Clients receive only the gateway token while upstream credentials stay in WordPress. Without the flag, Pi sessions stay on Roadie's pooled subscription credentials.

```bash
EXISTING_WP=~/Studio/my-site ./setup.sh --local --runtime opencode \
  --with-ai-gateway --ai-gateway-provider openai --ai-gateway-model gpt-4o-mini
```

The direct (non-Roadie) OpenCode Claude Pro/Max OAuth plugin resolves its
`claude-cli/<version>` client identity from the public npm registry's stable
`@anthropic-ai/claude-code` release. The installed Claude CLI is optional. Successful
lookups are cached for six hours and refreshed on subsequent requests, including
in long-running sessions. Registry requests have a three-second timeout, send no
OAuth credentials, and do not follow redirects. An unavailable or invalid registry
response retains the last good version and retries after five minutes; a fresh
offline install uses the bundled bootstrap version until discovery succeeds.
OpenCode stores this public metadata in
`${XDG_CACHE_HOME:-~/.cache}/opencode/claude-code-version.json`.
`OPENCODE_ANTHROPIC_USER_AGENT` overrides discovery entirely.

### Codex and Claude Code

These are no longer managed runtimes ([#751](https://github.com/Extra-Chill/wp-coding-agents/issues/751)). Run them in a terminal from the site root; they read the composed `AGENTS.md` (Claude Code through the `CLAUDE.md` symlink). Upgrade removes a stale managed `AGENTS.override.md` left by the old Codex projection (a user-owned one without the managed marker is left alone).

### Roadie

[Roadie](https://github.com/Extra-Chill/roadie) is the Discord surface and the only managed chat bridge. Setup installs the pinned Roadie release (`bridges/roadie/roadie-version`) and its [Pi](https://pi.dev) agent backend (`bridges/roadie/pi-version`, `@earendil-works/pi-coding-agent`), declared as top-level `dependency_stack` edges in `homeboy.json`. The hourly `Dependency refresh` workflow (homeboy-action `deps-refresh.yml`) folds non-breaking updates into the release commit, after Homeboy runs the provision, boot-smoke, and Pi-backend checks (`scripts.test`) against the refreshed pins and before tagging (boot-smoke requires network and Node >= 24). Breaking or unknown ranges become a review PR that has run the same checks. Pi is held within its current major version. VPS installs use root-owned prefixes under `/usr/local/lib/wp-coding-agents/`; local installs use the user's global npm. Pi is Roadie's only agent backend (Roadie v0.67.0 removed OpenCode), so the unit sets no `ROADIE_BACKEND`. It carries `ROADIE_PI_BIN` once `pi --version` passes Roadie's 1.x gate as the service user; when Pi does not verify, setup and upgrade report it, and Roadie looks for `pi` on `PATH` and fails at startup with its own error. `ROADIE_PI_MODEL` comes from the operator: pass `ROADIE_PI_MODEL=<provider/model>` to setup or upgrade, and an installed unit keeps the value it already carries. Without one, Pi uses `defaultProvider`/`defaultModel` from `settings.json` in Roadie's Pi agent dir (`<data-dir>/pi-agent`). `ROADIE_PI_TITLE_MODEL=<provider/model>` names a small model for thread titles, passed and kept the same way; without one, titles use the session model. `opencode.json` is not read for Roadie. With `--roadie-pool-url <url>` (and the bot's client key from `roadie credentials client add` on the pool host, passed once as `ROADIE_POOL_KEY` and stored as `<secrets>/pool-key`, mode 0600) the bot keeps no accounts and bills its Pi sessions through a shared pool host (`roadie credentials serve`); without the key it keeps its local pool and reports the gap. An admin client key (`client add <name> --admin`, passed once as `ROADIE_POOL_ADMIN_KEY` and stored as `<secrets>/pool-admin-key`) adds `ROADIE_POOL_ADMIN_KEY_FILE`, so `/credentials` and `/login` manage the pool host's accounts. `--roadie-pool-url local` switches back. Roadie runs with `ROADIE_MANAGED=1` so it never upgrades itself, and keeps secrets as files under `/etc/wp-coding-agents/roadie/` (`bot-token`, and a `send-token` the web user reads so scheduled dispatch can `roadie send` through the running bot without sudo). Roadie resumes runs that a restart interrupted.

Managed installs replace Roadie's generic prompt sections with a small bridge prompt (`ROADIE_PROMPT_CONFIG`) so orchestration, workspace, tunnel, and preview guidance come from the installed components that own those capabilities. The managed Roadie plugins (`host-upgrade`, `wordpress-context`, `wordpress-platform`, `fork-workspace`) are synced into Roadie's config directory. `wordpress-platform` registers WordPress itself as a Roadie chat platform: turns queued by the runtime-backed `agents/chat` handler arrive through the inbound-event connector, and the session's output is written back into the WordPress conversation run through the claim-token-bound `agents/*` write abilities. See [managed Roadie context](docs/roadie-managed-context.md).

**Migrating from Kimaki.** An upgrade on a Kimaki install migrates it in place: Kimaki is stopped, its session database is copied with an SQLite online backup and integrity check, attachments and projects are copied, the bot token, lock port, and agent slug are carried over, and the Kimaki unit is disabled. The subscription accounts move too: OpenCode's rotation pools (`<provider>-oauth-accounts.json`) and logins (`auth.json`) are imported into Roadie's shared credential pool (`roadie credentials import-opencode`), in the same order with the same active account, so nobody logs in again. Model choices follow: each direct model on those providers (`anthropic/claude-opus-5-5`, ...) in the stored channel, session and global choices gets a Roadie rotation of exactly that model (`roadie/anthropic-claude-opus-5-5`), and the choices point at it. Same model, now rotating across that provider's accounts; no routing policy is installed, and a rotation that already exists is kept. Add cross-provider fallbacks with `roadie credentials rotation set <name> <provider/model>...`. API-key providers are left as they are. This happens only while Kimaki is stopped, because refresh tokens rotate on use and two live copies invalidate each other. The Kimaki unit and `~/.kimaki` are left untouched as the rollback; a failed migration (database or accounts) restarts Kimaki.

Discord access is reconciled too, once the gateway is healthy: Roadie grants session access to the guild owner, Administrator, Manage Server, or a role named `Roadie` (case-insensitive), and Kimaki-era users hold a `kimaki` role, which Roadie stopped reading when it made a clean break from Kimaki install compatibility (roadie#32) — without this step every non-owner user is told to find a Roadie role that does not exist (#705). The migration renames `kimaki` to `Roadie` with the bot token when the bot has Manage Roles; otherwise, or when a `Roadie` role already exists, the upgrade summary carries the exact action (rename it by hand, or assign the existing role). The upgrade pass replays the reconciliation for installs cut over before this fix.

To roll back, swap the services: `systemctl disable --now roadie && systemctl enable --now kimaki`. Roadie has refreshed the subscription tokens since the migration, so Kimaki's copies are stale; log in again in OpenCode (`opencode auth login`) after the swap.

After the cutover, add accounts with Roadie's `/login` (or `/credentials login-anthropic`): that adds to the shared credential pool.

**Telegram and cc-connect were removed.** Roadie is the only bridge. Installs that used the Telegram or cc-connect bridges lose managed support: upgrade warns, leaves the existing service running as is, and no longer installs, configures, or updates it. New installs cannot select them. This lasts until Roadie supports more platforms ([Extra-Chill/roadie#14](https://github.com/Extra-Chill/roadie/issues/14)).

Inbound events queue independently of a runtime. Agents explicitly configured as runtime-backed route their `agents/chat` turns into the same queue: the mu-plugin registers an agents-api `wp_agent_chat_handler` for each agent slug listed under the `runtime-chat` entry of the inbound adapter config (`array( 'runtime-chat' => array( 'agents' => array( '<agent-slug>' => '<runtime-id>' ) ) )`, via the config filter or constant), validates permission as the authenticated WP user, enqueues exactly one durable event per turn (conversation_id = the WP `session_id`, with the message, attachments, acting user, and run_id), and returns a pending run. Unconfigured agents are untouched, and vendor and runtime names live only in installer-written config. The WP session is durably mapped to a runtime conversation ID on the first turn; a continuing session without a mapping fails closed. Answers to interactive questions arrive as further turns on the mapped session, and cancellation flows through the same queue via `wp_agent_chat_run_cancel_handler`. The runtime side claims events for its `runtime_id` with the existing `claim`/`acknowledge`/`retry` contract and acknowledges only after it accepts the turn; writing results back to the pending run depends on [Automattic/agents-api#585](https://github.com/Automattic/agents-api/issues/585).

The optional signed Slack adapter is configured through the inbound adapter config filter or constant with a signing secret, runtime ID, and explicit `allowed_team_ids` plus `allowed_channel_ids` allowlists.

```bash
bash tests/roadie-managed-env.sh
bash tests/roadie-kimaki-migration.sh
```

## Data Machine Memory

Data Machine manages the agent's persistent files:

| File | Scope | Purpose |
| --- | --- | --- |
| `SITE.md` | Site | Generated WordPress context |
| `RULES.md` | Site | Shared behavioral rules |
| `SOUL.md` | Agent | Agent identity and voice |
| `MEMORY.md` | Agent | Persistent project knowledge |
| `USER.md` | User | Human profile and preferences |

The selected runtime reads this memory at session start. Direct OpenCode installs reference the files from `opencode.json`. Under the Roadie bridge no static file references are synced: Roadie's `wordpress-context` plugin supplies the memory per session and speaker (`docs/roadie-user-context.md`), so Roadie's Pi sessions get current context without file wiring. The agent can update memory through Data Machine instead of relying on runtime-specific memory features.

## Abilities And Dispatch

Data Machine exposes tools through WordPress abilities. `wp-coding-agents` adds the local CLI transport that lets Data Machine send messages through installed chat bridges via the `agents/dispatch-message` contract.

Bridge channel registrations are conditional: only installed bridges register channels, and the generated guidance reflects only those channels.

## Verification

Useful local checks:

```bash
bash tests/agents-md-guidance.sh
bash tests/homeboy-agents-md.sh
bash tests/roadie-managed-env.sh
bash tests/roadie-kimaki-migration.sh
```

Use setup output and operator entrypoints for environment-specific verification commands. The generated summary is the source of truth for service names, paths, and bridge restart commands.

## Agent Self-Upgrade

On a managed VPS with a non-root service user, setup installs `/usr/local/sbin/wp-coding-agents-upgrade` and a sudoers grant that lets the service user run exactly `start` and `status`:

```bash
sudo /usr/local/sbin/wp-coding-agents-upgrade start
sudo /usr/local/sbin/wp-coding-agents-upgrade status
```

Roadie's `/upgrade-and-restart` and `roadie upgrade` call `start` through the bundled `host-upgrade.mjs` Roadie plugin (`ROADIE_PLUGINS`). `start` launches the upgrade in its own transient systemd unit (`wp-coding-agents-upgrade.service`), so it survives the bridge restart it causes. That unit fetches the root-owned checkout setup ran from, checks out `origin/main` detached, runs `upgrade.sh`, and restarts the site's enabled Roadie unit on success. The caller supplies no path, ref or content, so the agent decides when an upgrade runs, never what runs. The command is installed only when the checkout and every parent directory are root-owned and not group- or world-writable; otherwise the grant would amount to a root shell. Config: `/etc/wp-coding-agents/self-upgrade.conf`. One site per host.

Opt-in flags for that unattended `upgrade.sh` run (currently `--wordpress-chat-agent`) are declared in a reviewed git repo, not passed by the agent. Record it once with `--host-config-repo <git-url> --host-config-path <path-in-repo>` (and optionally `--host-config-ref`, default `main`); the values persist in `self-upgrade.conf` across upgrades. During `apply` the wrapper fetches that repo into a root-owned bare mirror (`/var/lib/wp-coding-agents/host-config.git`) and reads the file with `git show <ref>:<path>` — never a working tree — so only merged content takes effect. The file is `KEY=value` lines against an allowlist (`WORDPRESS_CHAT_AGENT=<slug>`); unknown keys, malformed lines or invalid values fail the apply before `upgrade.sh` runs, and a key removed from the repo removes its effect (`--no-wordpress-chat` tears the connector down and deletes its durable env file). The sudoers grant is unchanged: exactly `start` and `status`.

## Verification

```
./verify.sh                 # exits non-zero on any disagreement
./verify.sh --json          # machine-readable, for a scheduled check
```

Every defect that reached a live site during the managed-hosting rollout was a
disagreement *between* layers, not a fault within one: a unit whose `User=` and
`HOME=` described different identities, a manifest that had drifted from the
recorded set, a declared source the permission surface did not allow, a function
guarded by `declare -F` in a script that never sourced its library.

Each component was internally correct and individually tested. Nothing owned the
seam, so nothing failed until somebody looked — and the looking is what does not
scale. An operator with two sites inspects a rendered systemd unit before
starting services; an operator with two thousand does not.

`verify.sh` owns the seams. It reports and never repairs: a check that fixes what
it finds cannot be trusted to report honestly, and the failure it hides is the
one worth seeing. An invariant it cannot evaluate is reported as skipped rather
than passed.

## Upgrades

On a managed VPS, `/upgrade-and-restart` in Discord (or `roadie upgrade` on the host) upgrades the install: Roadie's `host_upgrade` hook calls the [agent self-upgrade command](#agent-self-upgrade), which runs what is merged to `main` and restarts Roadie when it finishes. On a local macOS (launchd) install, the same hook starts the one-shot `com.wp.roadie-upgrade` launchd job (`scripts/roadie-local-upgrade`): it fetches `main`, installs the Roadie release pinned there (whatever branch this checkout has checked out) and restarts `com.wp.roadie`, logging to `$ROADIE_DATA_DIR/roadie-upgrade.log` and recording the result in `roadie-upgrade-state.json`. It moves Roadie only; if `main` can't be fetched it records a failure and leaves Roadie as it is. Elsewhere, run `./upgrade.sh`; it preserves user state, syncs managed bridge and runtime files, and prints verification and restart commands for the detected environment. Earlier installs carried an `upgrade-wp-coding-agents` agent skill for this; upgrades remove it.

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
- [Homeboy](https://github.com/Extra-Chill/homeboy) — Optional orchestration/lab layer for repo-aware coding workflows.
- [Roadie](https://github.com/Extra-Chill/roadie) — Discord bridge (Pi agent backend), installed with the OpenCode runtime.

## Contributing

Issues and PRs are welcome.

## License

MIT — see [LICENSE](LICENSE).

---

Built by [Extra Chill](https://extrachill.com).
