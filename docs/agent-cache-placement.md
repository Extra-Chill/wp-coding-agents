# Agent cache placement (phase 1)

On Linux VPS installs, the existing explicitly declared repository workspace
(`DM_WORKSPACE_DIR`, the first `--workspace-repository`) is also the cache
placement root. Put that repository on the dedicated workspace volume.
Setup and upgrade create private, service-user-owned directories under
`<workspace>/.agent-cache` before reconciling bridge/agent units:

| Environment | Directory |
| --- | --- |
| `XDG_CACHE_HOME` | `xdg` |
| `PNPM_STORE_DIR` | `pnpm` |
| `PLAYWRIGHT_BROWSERS_PATH` | `playwright` |
| `npm_config_cache` | `npm` |
| `COMPOSER_CACHE_DIR` | `composer` |
| `CARGO_HOME` | `cargo` |
| `RUSTUP_HOME` | `rustup` |

Roadie, Homeboy daemon, and agent worker systemd units inherit these settings.
Paths are quoted for systemd, including workspaces containing spaces. With no
workspace, or on macOS/local installs, cache placement does nothing. Dry runs
create nothing. Existing service restart/reconciliation behavior applies.

This does **not** move existing caches, credentials, Cargo-installed binaries,
toolchains, bridge sessions, Homeboy config, or SQLite databases, and does not
set `XDG_DATA_HOME`. Tools populate fresh caches/toolchains as needed; old state
remains available for a separately planned maintenance migration. No live-store
migration or automatic deletion is performed.

`verify.sh --site-path <site>` includes a read-only agent-state disk doctor.
It reads the workspace from the installation profile and the agent home from
`SERVICE_HOME` or the Roadie systemd service user. When at least 1 GiB of known
agent state shares the site's filesystem, it emits a warning (also in JSON
findings), without failing the invariant checks. `AGENT_STATE_WARNING_KB`
overrides the threshold. It skips symlinked state and other filesystems, and
never repairs or migrates state. The site path represents production storage;
for separately mounted site data, use the relevant site filesystem when
calling the underlying `agent_state_doctor <agent-home> <site-data-path>` probe.

Refs #881. Existing state and live SQLite migration are follow-up work.
