# Automatic host-owned fork worktrees

The managed `fork-workspace.mjs` provider connects Roadie's `fork_workspace`
hook to Homeboy's native worktree lifecycle. `/fork` allocates automatically;
there is no shared/separate selector or default mode.

## Repository ownership

For an existing Git-root or worktree-bound conversation, the current checkout
identifies the source directly, including when another task is awaiting admission.
For a conversation rooted
outside Git (such as a WordPress site home), the provider reads Homeboy's
indexed active-task ownership by the source session's opaque caller reference.
Task admission records the controller checkout, and terminal lifecycle state
removes its ownership from the active projection. The shell adapter captures
the actual session ID in `HOMEBOY_CALLER_CONTEXT`; it replaces inherited parent
ownership on a fork without reading the conversation.

One active checkout is selected and verified through Git's common directory.
Several active branches in the same Git repository identify a coordinator. Its
fork uses the verified primary repository checkout's committed HEAD and allocates
an independent worktree. Active branches retain their own commits and lifecycle.
For a non-Git source, any pending allocation, different active repositories,
invalid ownership, or a missing owner checkout returns `null` from the filter.
Unavailable or malformed active-scope discovery also returns `null`. Roadie then
runs its ordinary shared fork in the source directory, where the conversation
already operates. No active task and no Git-bound source likewise retain ordinary
conversation forks. Isolation is selected only when ownership is unambiguous and
resolvable; pending runs take precedence even if other owners are resolvable. Historical activity and maintenance commands supply no
repository candidates. Ownership lookup never scans a transcript or run history.

The verified checkout path is a native Homeboy lifecycle handle. Fresh repositories
need no component registration or source configuration file. The host allocates
directly from that path without scanning the component registry.
An optional operator-owned `roadie-config/fork-workspaces.json` restricts the
eligible repositories:

```json
{
  "version": 1,
  "projects": [
    {
      "directory": "/code/project"
    }
  ]
}
```

`WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG` selects another configuration path.
Source and target identity is verified by Git, including existing worktrees.

## Allocation and binding

The provider asks Homeboy to create a unique branch/worktree from the selected
checkout's committed HEAD, with a `roadie-fork-<request ID>` owner and
`preserve-on-failure` cleanup policy. It verifies the resulting commit. Dirty
source files stay in the source and are not copied into the fork.

Roadie discovers the new workspace under the target repository, forks the
original conversation normally, and warps only the copy with
`copyChanges: false`. The original conversation keeps its home directory.
Roadie stores Homeboy's workspace handle in its conversation binding.
Abandoned setup finalizes that record as failed, retaining evidence; Homeboy
owns later cleanup. This uses the existing lifecycle.

Site-root isolation requires Homeboy's `agent-task active-scope` indexed
ownership contract and the source-session fork hook in Roadie. An older or
unavailable controller leaves a non-Git conversation's fork shared; it never
falls back to conversation scanning. Git-bound sources bypass ownership discovery.
Host allowlist refusals and worktree provisioning or binding failures remain
errors from this provider; Roadie degrades them to a shared fork with a visible
notice, so a fork is never cancelled.
Restart the bridge after upgrading the provider.

## Verification

`bash tests/roadie-fork-workspace.sh` uses a real Homeboy CLI with isolated
HOME/config, real Git worktrees and independent writes. It proves dirty-source
preservation, committed-base parity, retained failure evidence, a non-Git home
selecting an admitted checkout, task switching and cancellation through separate
CLI processes, and terminal-owner expiry. Active ownership is fixture-seeded
because the current CLI has no queue-only admission verb; worktree allocation,
finalization and status use the real Homeboy CLI. A table-driven fallback matrix
checks that pending, ambiguous, unavailable, malformed, invalid and missing
ownership return `null` from the real filter. An empty scope also uses the real
CLI directly. Git-bound discovery bypass and host allowlist enforcement remain
covered.
Use `HOMEBOY_FORK_TEST_COMMAND` to select the exact candidate controller binary
when verifying the upstream dependency before its release.
