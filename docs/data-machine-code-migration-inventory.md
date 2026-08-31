# Data Machine Code migration inventory

The authoritative inventory for [#527](https://github.com/Extra-Chill/wp-coding-agents/issues/527) is [`data-machine-code-migration-inventory.json`](./data-machine-code-migration-inventory.json). JSON is intentional: ownership and migration decisions gate the implementation issues under #525 and must remain machine-checkable.

The decision record includes reopened #455, #525 through #530, the completed #474 adapter tracker, and merged PRs #516 and #517. PR #516 removed wp-coding-agents' copied-release ownership but did not satisfy #455's shared reconciler contract. PR #517 made Homeboy the effective worktree owner while deliberately retaining DMC ability schemas; those remaining seams are inventory evidence, not the target architecture.

## Scope

The census covers the primary checkouts of wp-coding-agents, Data Machine Code, Data Machine, Intelligence, WP Codebox, Homeboy, and Homeboy Extensions at the revisions recorded in the JSON. It separates active runtime dependencies, entrypoints, persisted contracts, tests, current guidance, history, and negative repository censuses.

Each row identifies a source path and symbol or command, current owner and consumers, persisted-state implications, target owner, move/replace/extract/delete disposition, migration issue, and verification gate. A retained surface requires a named consumer. A negative census means no DMC-named runtime dependency was found; it does not mean the repository has no generic Data Machine or Homeboy integration.

## Ownership rules

- **wp-coding-agents** owns runtime installation, repository/workspace policy, host capabilities, coding guidance, upgrades, and verification.
- **Data Machine** owns generic agent identity, memory, abilities, flows, jobs, bundles, and AGENTS.md composition.
- **Homeboy** owns orchestrated worktree lifecycle, evidence, promotion, release, retention, and cleanup.
- **WordPress integration package** means the focused package from #530, used only for confirmed in-process WordPress consumers.
- **retire** means no target implementation is justified. Persisted state still requires a query and terminal migration decision before deletion.

## Installed-state gate

Source evidence cannot prove the contents of long-lived WordPress databases, bundle directories, queued jobs, or Homeboy configuration. Before #528 removes aliases or #525 removes DMC, run the `installed_state_queries` against representative local, VPS, Studio/external WordPress, and Homeboy-enabled installations. Record a replacement or explicit retirement for every returned DMC ability, handler, tool, flow, bundle artifact, option, table row, queue item, and external command reference.

The four entries under `unresolved_classifications` are bounded decisions, not indefinite compatibility promises. If a query identifies a real shell-less GitHub/pipeline consumer, create a focused extraction tracker. Do not transplant the DMC control plane.

## Validation

Run:

```sh
bash tests/dmc-migration-inventory.sh
```

The validator checks schema fields and enum values, requires every top-level DMC subsystem to have a disposition, and scans repository source for stable DMC lexical families. Every matching file and exact named contract must be classified. It deliberately does not pin line numbers, match counts, DMC ability totals, or file contents.
