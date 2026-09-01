# Workspace ownership after DMC

Status: active architecture for [#526](https://github.com/Extra-Chill/wp-coding-agents/issues/526), completed as a prerequisite to [#525](https://github.com/Extra-Chill/wp-coding-agents/issues/525).

This document defines where coding work happens and which layer owns each operation after DMC is removed. The migration inventory remains the source of truth for current dependencies and persisted-state gates.

## Invariants

1. Source mode declares where edits land. It is not inferred from plugin presence.
2. `wp-coding-agents` owns the desired runtime shape and the exact repository roots available to that runtime.
3. Coding runtimes use their native filesystem, search, shell, Git, and GitHub tools against those roots. WordPress does not proxy ordinary repository work.
4. Homeboy is the only owner of orchestrated worktree lifecycle. Enabling Homeboy does not transfer repository authority or create a second repository inventory.
5. Data Machine owns agent identity, memory, abilities, flows, jobs, bundles, and composed guidance. It does not own coding workspaces.
6. WordPress exposes only the focused in-process capabilities enumerated below. It does not regain a general repository, Git, GitHub, or worktree control plane.
7. Missing repository or orchestration evidence fails closed. The runtime must not guess a checkout, edit installed reference source, or imply that an unavailable worktree manager exists.

## Supported shapes

| Source/runtime shape | Repository authority | Change path | WordPress relationship |
| --- | --- | --- | --- |
| Colocated workspace, interactive local or VPS | Exact repository roots in the `wp-coding-agents` desired-state profile | Runtime edits a configured primary checkout and uses native Git/GitHub tools | Installed WordPress source is read-only reference; WP-CLI runs directly against the site |
| Colocated workspace with Homeboy | The same exact configured roots, attached as Homeboy components | Interactive work may use a primary checkout; orchestrated work uses Homeboy-created worktrees and Homeboy promotion/finalization | WordPress remains reference and application runtime; it does not create or track worktrees |
| External WordPress workspace | Exact roots mounted on the runtime host; remote WordPress paths are never repository roots | Runtime uses native tools locally | The operator-supplied argv transport is authoritative for WordPress control and projected Data Machine context |
| External WordPress workspace with Homeboy | The same runtime-local configured roots, attached as Homeboy components | Homeboy owns orchestrated worktrees on the host where those repositories exist | WordPress control still crosses only the explicit transport; no remote workspace is inferred |
| Owned source | The declared/derived owned paths under the installed site | Runtime edits those paths in place; operator infrastructure captures changes out of band | There is no repository workspace, Git workflow, GitHub workflow, or worktree control plane in the agent contract |
| WordPress in-process caller | No repository authority | Caller invokes only a named resident capability below | WordPress is the execution host, not a coding workspace manager |

Homeboy is an optional orchestration axis, not a source mode. When it is unavailable, workspace mode remains valid: the runtime works directly in configured primary checkouts with native tools. No managed worktree commands are advertised, no WordPress fallback is installed, and no worktree state is synthesized.

## Repository contract

The desired-state profile carries an explicit list of repository roots for workspace mode. Existing checkouts are declared by absolute path. A repository object with `path` and credential-free `remote` fields additionally authorizes setup and upgrade to clone that primary checkout when the destination is missing.

- Each entry is an absolute path to one primary Git checkout accessible to the coding runtime. Filesystem aliases are resolved when proving checkout-root identity.
- Materialization creates only a missing destination. An existing destination must already be the primary checkout root and its `origin` must exactly match the declaration; setup and upgrade never replace it.
- Materialization rejects direct symlink destinations and user-controlled symlink ancestors. Privileged materialization additionally requires root-owned ancestors that are not group/world-writable; root-owned aliases in protected system directories remain valid.
- The list is the sole repository authority for runtime permissions, guidance, verification, and optional Homeboy component attachment.
- The WordPress site root is read-only reference unless it is separately and explicitly listed as a repository root. Local path coincidence is not authority.
- Directory scanning, plugin inventories, `homeboy.json`, and DMC options may help migrate an existing install, but none is ongoing repository discovery authority.
- A Homeboy component references the same configured primary checkout. Task worktrees, including `repo@branch` paths, are never promoted into primary repository entries.
- A workspace profile with no valid configured repository fails verification and exposes no mutable source target. It never falls back to installed WordPress source.
- Repository identity and checkout freshness come from native Git. `wp-coding-agents` validates reachability and policy; it does not implement Git state.

### Primary-checkout policy

Without Homeboy, the configured primary checkout is the runtime's working checkout. The agent may create a branch, edit, test, commit, push, and open a pull request with native tools. The repository's own contribution policy remains authoritative.

With Homeboy, the primary checkout remains the stable component source. Homeboy creates and records isolated task worktrees, owns their status and cleanup, and performs explicit promotion or finalization. An interactive operator may still choose direct native work in the primary checkout, but `wp-coding-agents` and WordPress do not present that as a managed Homeboy run.

An ad hoc `git worktree` created outside Homeboy is ordinary native Git state. It receives no orchestration guarantees, is not auto-attached as a component, and is not tracked or cleaned by WordPress.

## Operation owners

| Operation | Sole owner | Contract |
| --- | --- | --- |
| Source mode, desired component set, repository-root declaration, runtime permissions, guidance, setup, upgrade, and verification | `wp-coding-agents` | One desired-state profile converges setup and upgrade |
| File reads/writes, search, shell execution, Git state and commits, and GitHub pull-request operations | Selected coding runtime and its native tools | Operate only on configured repository roots or declared owned paths |
| Agent identity, memory, flows, jobs, bundles, and AGENTS.md composition | Data Machine | Generic operating layer; no workspace semantics |
| WordPress command transport | `wp-coding-agents` | Direct colocated WP-CLI or one explicit external argv transport |
| Orchestrated worktree create, status, finalization, retention, cleanup, context projection, and run attribution | Homeboy | Available only when Homeboy is selected and verified |
| Direct owned-source edits | Selected coding runtime under `wp-coding-agents` policy | Exact owned and writable path declarations |
| Out-of-band capture of owned-source edits | Operator-selected capture system | Outside workspace mode; not implied to be Homeboy |
| WordPress-resident host and channel capabilities | Focused WordPress integration package from #530 | Only the consumer-bound surface below |
| Releases and deployments | Homeboy when explicitly invoked by the operator | Never an implicit consequence of setup, upgrade, or workspace cleanup |

## WordPress-resident capabilities

The migration inventory proves these retained in-process consumers:

| Capability | Consumer | Target contract |
| --- | --- | --- |
| Shell/process-runtime availability | Intelligence MCP context bridge manager | Neutral host-environment API in the focused WordPress integration package |
| Writable-filesystem availability | Intelligence REST memory fallback | The same neutral host-environment API |
| Canonical CLI channel registration and dispatch | Kimaki, cc-connect, Telegram, and generated CLI transport | Canonical `wp-coding-agents` channel registry in the focused package |

The constrained process-path probe remains conditional. Its host helper and exact-argv security boundary are `wp-coding-agents` concerns, but a WordPress facade belongs in the focused package only if migration design identifies a retained in-process consumer.

The following are not target resident capabilities: repository discovery; file mutation; Git or GitHub operations; workspace creation; worktree lifecycle; code-task creation; source inventory; PR-review scaffolding; or a general ability projection of coding-runtime tools. Persisted references to old abilities, channels, flows, bundles, jobs, and callbacks are migration inputs, not justification for a permanent compatibility control plane.

## Failure behavior

- Missing materialized repositories are restored from their declarations during setup or upgrade. Missing path-only repositories and invalid destinations make workspace verification unhealthy and leave installed WordPress source read-only.
- Missing Homeboy leaves native primary-checkout workflow available and all orchestrated-worktree guidance absent.
- Homeboy configured but unhealthy fails the Homeboy seam explicitly; WordPress does not assume its lifecycle operations.
- An unavailable external WordPress transport blocks WordPress operations but does not change local repository authority.
- An unavailable focused WordPress capability fails at its named consumer boundary and does not install a broader workspace service.
- Owned mode with no owned paths remains read-only and reports that no editable source is configured.

## Follow-up implementation

- [#455](https://github.com/Extra-Chill/wp-coding-agents/issues/455): make setup and upgrade converge the same desired component and repository state.
- [#530](https://github.com/Extra-Chill/wp-coding-agents/issues/530): provide the focused WordPress package and explicit component intent.
- [#528](https://github.com/Extra-Chill/wp-coding-agents/issues/528): replace old runtime, ability, channel, process-probe, attribution, guidance, and persisted contracts with the owners above.
- [#529](https://github.com/Extra-Chill/wp-coding-agents/issues/529): require DMC-absent setup/upgrade, native repository, Homeboy, Intelligence, and WP Codebox fixtures.
- [#525](https://github.com/Extra-Chill/wp-coding-agents/issues/525): run the installed-state census, resolve every persisted reference, remove the old plugin paths, and complete consolidation only after #529 passes.

Setup summaries and generated guidance must name configured repositories rather than a generic managed workspace. Verification must prove the repository roots, native tracked-change path, selected WordPress transport, focused resident capabilities, and direct Homeboy readiness when enabled.
