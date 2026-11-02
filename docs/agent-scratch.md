# Agent scratch retention (#853)

Fixes #853.

`--agent-tmpdir` continues to select the workspace-backed `TMPDIR`; service
environments and the existing tmpfiles.d record are unchanged. A short generic
AGENTS.md section is registered only with that configuration. It directs scratch,
ad-hoc clones, and build output to `$TMPDIR` or managed worktrees, including an
explicit `CARGO_TARGET_DIR` for ad-hoc builds.

## Backstop design

The same agent-tmpdir adapter installs `wp-coding-agents-tmp-sweep.service` and a
daily, persistent timer on systemd hosts only (not local/macOS installations).
Dry runs do not write files or invoke systemctl. The helper is root-owned but
runs as `SERVICE_USER`, refuses UID 0, and only scans top-level `/tmp` entries.
Unlike a broad tmpfiles rule, it can enforce an ownership filter without cleaning
unrelated users' temporary files.

`AGENT_TMP_SWEEP_MAX_AGE` overrides the sweep age; otherwise it inherits
`AGENT_TMPDIR_MAX_AGE`, defaulting to `3d`. The sweep accepts positive integer
`s`, `m`, `h`, `d`, or `w` durations (set these in the installer environment).
The existing workspace tmpfiles age syntax is unchanged. Unsupported sweep ages
fail reconciliation rather than silently choosing a different retention period.

An entry is removed only if its entire tree is owned by the service UID and all
access, modification, and change timestamps are older than the cutoff. Root and
foreign-owned descendants, sockets, symlinks, special files, mount boundaries,
and `systemd-private-*` names protect the whole tree. Traversal uses directory
file descriptors and no-follow opens; concurrent filesystem changes are skipped.
The non-root identity and systemd sandbox limit the consequences of races. This
is a stale-scratch backstop, not an active-build detector or a disk quota; recent
or protected entries can remain indefinitely. Operators can inspect runs with
`journalctl -u wp-coding-agents-tmp-sweep.service` and timer state with
`systemctl list-timers wp-coding-agents-tmp-sweep.timer`.

## Disk-pressure signal

Deferred: the repository's health paths check integration invariants, managed
unit state, and capability drift, rather than ongoing host resource health.
Adding a disk alarm there would only run during installer/verification activity,
not continuously ahead of a database outage. No host disk monitor is introduced
in this change; items 1 and 2 are the deliverable.

## Validation

- `bash tests/bridge-service-adapters.sh`: guidance, user/age rendering,
  configuration/platform gates, dry-run, and disposable-tree cleanup behavior.
- `bash tests/homeboy-daemon-service.sh`
- `bash tests/agents-md-guidance.sh`
- `bash tests/runtime-guidance-desired-state.sh`
- `bash tests/bridge-render.sh --update` and `bash tests/bridge-render.sh`:
  existing bridge fixtures are unchanged.

The behavioral tests cover stale files and clone/build trees, recent descendants,
symlinks, sockets, systemd-private names, invalid ages, and (when run as root)
root refusal and foreign-owned trees via an unprivileged subprocess.
