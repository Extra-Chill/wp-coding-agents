# Automatic host-owned fork worktrees

The managed `fork-workspace.mjs` provider connects Roadie's `fork_workspace`
hook to Homeboy's native worktree lifecycle. `/fork` allocates automatically;
there is no shared/separate selector or default mode.

## Repository ownership

For an existing Git-root or worktree-bound conversation, the current checkout
identifies the source. For a conversation rooted outside Git (such as a
WordPress site home), Roadie supplies `codingPaths` from successful persisted
coding-tool activity. The provider resolves those locations through Git's
common directory and requires one unique repository. Within that repository,
the most recent coding location selects the checkout and its exact HEAD.
Unrelated reads and prose are not scope. Multiple repositories fail with a
useful explanation; no coding repository retains ordinary conversation forks.

By default ownership is discovered from `homeboy component list` using
registered repository-root components. Subdirectory components do not compete
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

Requires the automatic coding-scope contract in Roadie PR #116 and OpenCode's
existing experimental workspace APIs (released OpenCode 1.18.31).
The managed provider enables `OPENCODE_EXPERIMENTAL_WORKSPACES=true` before
Roadie starts the backend; an explicit host environment value takes precedence.
Restart the bridge after upgrading the provider. Missing support,
discovery or binding fails before a fork task runs.

## Verification

`bash tests/roadie-fork-workspace.sh` uses a real Homeboy CLI with isolated
HOME/config, real Git worktrees and independent writes. It proves dirty-source
preservation, committed-base parity, retained failure evidence, a non-Git home
selecting an active checkout at a newer commit, automatic registry ownership,
nested-fork scope precedence, and ambiguity/unregistered-repository refusal.
