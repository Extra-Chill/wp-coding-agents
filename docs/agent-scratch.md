# Agent scratch retention

With `AGENT_TMPDIR` configured, rendered systemd services carry both
`Environment=TMPDIR=<dir>` and `BindPaths=<dir>:/tmp` in `[Service]`.
Inside those services, literal `/tmp` paths and `$TMPDIR` reach the same scratch
on the workspace volume. The agent-tmpdir adapter creates the source before
units start; the existing tmpfiles rule reclaims scratch after
`AGENT_TMPDIR_MAX_AGE` (default `3d`). Long-lived work belongs in a Homeboy worktree.

The bind replaces a host `/tmp` sweep: scratch lands on the correct volume
rather than filling root until cleanup, without scanning unrelated host files.
Guidance alone cannot redirect literal `/tmp` paths. Without `AGENT_TMPDIR`,
units are unchanged. launchd keeps TMPDIR only; macOS has no equivalent bind.

Rollout requires `upgrade.sh` and restarting `roadie` and `homeboy-daemon` on
hosts. The real-renderer table in `tests/bridge-render.sh` checks both directives
in `[Service]` for both units, including unset configuration and paths with spaces.

Refs #853. Disk-pressure alerting remains out of scope; the issue stays open.
