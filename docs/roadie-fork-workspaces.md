# Automatic host-owned fork worktrees

The managed `fork-workspace.mjs` provider connects Roadie's `fork_workspace`
hook to Homeboy's native worktree lifecycle. `/fork` allocates automatically;
there is no shared/separate selector or default mode.

## Repository ownership

For an existing Git-root or worktree-bound conversation, the current checkout
identifies the source when there is no active task. For a conversation rooted
outside Git (such as a WordPress site home), the provider reads Homeboy's
indexed active-task ownership by the source session's opaque caller reference.
Task admission records the controller checkout, and terminal lifecycle state
removes its ownership from the active projection. The shell adapter captures
the actual session ID in `HOMEBOY_CALLER_CONTEXT`; it replaces inherited parent
ownership on a fork without reading the conversation.

One active checkout is selected and verified through Git's common directory and
its registered repository owner. Multiple active checkouts or pending allocation
fail with an explanation. No active task and no Git-bound source retain ordinary
conversation forks. Historical activity and maintenance commands supply no
repository candidates. Ownership lookup never scans a transcript or run history.

An active task names its registered repository directly; the host uses
`homeboy component show` for that owner. Repository-bound conversations without
an active task use the component registry. Subdirectory components do not compete
with their owning repository. An unregistered coding repository fails closed.
An optional operator-owned `roadie-config/fork-workspaces.json` restricts the
eligible repositories:

```json
{
  "version": 1,
  "projects": [
    {
      "directory": "/code/project",
      "component": "project"
    }
  ]
}
```

`WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG` selects another configuration path.
Projects must already be registered with Homeboy. Source and target identity
is verified by Git, including when activity occurs in an existing worktree.

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

Requires Homeboy's `agent-task active-scope` indexed ownership contract and the
source-session fork hook in Roadie. An older controller fails closed instead of
falling back to conversation scanning. Also requires OpenCode's
existing experimental workspace APIs (released OpenCode 1.18.31).
The managed provider enables `OPENCODE_EXPERIMENTAL_WORKSPACES=true` before
Roadie starts the backend; an explicit host environment value takes precedence.
Restart the bridge after upgrading the provider. Missing support,
discovery or binding fails before a fork task runs.

## Verification

`bash tests/roadie-fork-workspace.sh` uses a real Homeboy CLI with isolated
HOME/config, real Git worktrees and independent writes. It proves dirty-source
preservation, committed-base parity, retained failure evidence, a non-Git home
selecting an admitted checkout, task switching and cancellation through separate
CLI processes, terminal-owner expiry, and ambiguity/pending-allocation refusal.
Use `HOMEBOY_FORK_TEST_COMMAND` to select the exact candidate controller binary
when verifying the upstream dependency before its release.
