# Host-owned fork workspaces

The managed `fork-workspace.mjs` plugin connects Roadie's `fork_workspace` hook
to Homeboy's native worktree lifecycle. It activates only with operator-owned
`roadie-config/fork-workspaces.json`:

```json
{
  "version": 1,
  "projects": [
    {
      "directory": "/code/project",
      "component": "project",
      "defaultMode": "separate"
    }
  ]
}
```

`WP_CODING_AGENTS_FORK_WORKSPACES_CONFIG` can select another config path. Projects
must already be registered with Homeboy. Directory matching uses Git's common
directory, so forks from existing worktrees resolve to the same owner. A
multi-repository WordPress site root is not guessed to be a Git project.

For separate forks the provider asks Homeboy to create a unique branch/worktree
from the source checkout's exact HEAD, with a `roadie-fork-<request ID>` owner and
`preserve-on-failure` cleanup policy. It verifies the resulting commit. Dirty
source files are preserved in the source and never copied into the fork.

Roadie stores Homeboy's workspace handle in its conversation binding. Abandoned
fork setup finalizes the Homeboy record as failed, retaining evidence; Homeboy
owns later cleanup. This is allocation through the existing lifecycle, not a
second worktree implementation.

Requires Roadie's fork-workspace hook (#106) and OpenCode's existing experimental
workspace APIs, verified on released OpenCode 1.18.31. Configure
`OPENCODE_EXPERIMENTAL_WORKSPACES=true` in the managed backend's startup environment
and restart when activating the feature. Roadie discovers the Homeboy-owned Git
worktree, forks normally, and warps the copied session with `copyChanges: false`.
It verifies the persisted native workspace binding before running a task. An
OpenCode source patch is not required; missing support or discovery fails closed.

Verification: `bash tests/roadie-fork-workspace.sh`. The test uses a real Homeboy
CLI with isolated HOME/config, two real Git worktrees and actual independent
writes. It proves committed-base parity, dirty-source preservation, distinct
workspaces and retained failure evidence.
