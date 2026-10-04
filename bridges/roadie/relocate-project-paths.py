#!/usr/bin/env python3
"""Relocate operational project-directory bindings after the Kimaki copy (#660).

The Kimaki → Roadie migration copies <kimaki-data>/projects into
<roadie-data>/projects byte-for-byte, but the copied session database still
binds channels, thread working directories, and scheduled tasks to paths
beneath the retired Kimaki data directory. Removing the retired directory
then breaks live channels whose projects were copied correctly.

This rewrites those stored references with a component-safe source→target
prefix mapping. A value is relocated only when it equals the source projects
root or starts with the source root followed by a path separator, so
/srv/.kimaki/projects and /srv/.kimaki/projects-extra never confuse each
other, and any suffix (including a trailing separator) survives verbatim.
Everything else is preserved exactly: paths outside the copied root (site
checkouts, external worktrees), historical error text (last_error, error),
and conversation payloads (session_events) are never touched. Application is
idempotent: rows already pointing at the target map to themselves.

OpenCode owns its session directories. Their dependencies are reported as
cleanup blockers rather than changing another runtime's persistent storage.

  relocate-project-paths.py apply --db <db>
                                  --source-root <retired projects dir>
                                  --target-root <copied projects dir>
                                  [--require-target-exists]
      rewrite the references; per-table counts on stdout

--require-target-exists rewrites a value only when the mapped target path
already exists on disk. The fresh migration copies the projects first, so it
does not need this; repairing a Roadie copy migrated before this fix does —
a live channel is never pointed at a directory that was never copied, and
values whose target is missing are reported instead.

<db> is the Roadie copy of discord-sessions.db. Kimaki-era databases carry a
subset of Roadie's schema (thread_worktrees instead of thread_workspaces, no
scheduled tasks), so every table and column is checked against sqlite_master
and skipped when absent, the same contract repoint-models.py uses.
"""

import argparse
import os
from pathlib import Path
import sqlite3

# Operational directory references owned by these tables. Columns are checked
# against the actual schema; historical text columns (last_error, error) and
# conversation payloads (session_events.event_json) are deliberately absent.
PATH_COLUMNS = [
    ("channel_directories", ("directory",)),
    ("thread_workspaces", ("project_directory", "workspace_directory")),
    ("thread_worktrees", ("project_directory", "worktree_directory")),
    ("scheduled_tasks", ("project_directory",)),
    ("scheduled_task_runs", ("project_directory",)),
]


def mapped_target(value, source_root, target_root):
    """Target path for a value beneath the source root, else None.

    Component-safe: the source root must match to a path boundary, and the
    remainder of the value is carried over unchanged.
    """
    if not isinstance(value, str) or not value:
        return None
    if value == source_root:
        return target_root
    if value.startswith(source_root + "/"):
        return target_root + value[len(source_root):]
    return None


def schema_tables(connection):
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    return {
        table: {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        for table in tables
    }


def apply(args):
    source_root = args.source_root.rstrip("/") or "/"
    target_root = args.target_root.rstrip("/") or "/"
    if not os.path.isabs(source_root) or not os.path.isabs(target_root) or "/" in (source_root, target_root) or source_root == target_root:
        raise SystemExit(
            "refusing relocation: source and target roots must be distinct non-root paths"
        )

    connection = sqlite3.connect(Path(args.db).resolve().as_uri() + "?mode=rw", uri=True)
    unresolved = 0
    try:
        with connection:
            schema = schema_tables(connection)
            relocated_somewhere = False
            for table, path_columns in PATH_COLUMNS:
                if table not in schema:
                    continue
                usable = [name for name in path_columns if name in schema[table]]
                if not usable:
                    continue
                relocated = 0
                for (rowid, *values) in connection.execute(
                    f"SELECT rowid, {', '.join(usable)} FROM {table}"
                ).fetchall():
                    targets = [mapped_target(value, source_root, target_root) for value in values]
                    changed = [
                        (index, target)
                        for index, (value, target) in enumerate(zip(values, targets))
                        if target is not None and target != value
                    ]
                    if not changed:
                        continue
                    for index, target in changed:
                        if args.require_target_exists and not os.path.isdir(target):
                            print(f"{table}: left at retired path (target not copied): {values[index]}")
                            unresolved += 1
                            continue
                        if not args.dry_run:
                            connection.execute(
                                f"UPDATE {table} SET {usable[index]} = ? WHERE rowid = ?",
                                (target, rowid),
                            )
                        relocated += 1
                        relocated_somewhere = True
                noun = "binding(s)" if table == "channel_directories" else "reference(s)"
                print(f"{table}: {relocated} {noun} relocated")
            if relocated_somewhere and "thread_sessions" in schema:
                count = connection.execute("SELECT count(*) FROM thread_sessions").fetchone()[0]
                if count:
                    print(f"thread_sessions: {count} session mapping(s) kept")
    finally:
        connection.close()
    # Backend session directories belong to OpenCode. Preserve their identities
    # and report a cleanup blocker instead of silently orphaning their history.
    if args.opencode_db and Path(args.opencode_db).is_file():
        backend = sqlite3.connect(Path(args.opencode_db).resolve().as_uri() + "?mode=ro", uri=True)
        try:
            schema = schema_tables(backend)
            if "directory" in schema.get("session", set()):
                count = sum(mapped_target(row[0], source_root, target_root) is not None
                            for row in backend.execute("SELECT directory FROM session"))
                if count:
                    print(f"OpenCode: {count} session directory reference(s) require relocation before retiring the source")
                    unresolved += count
        finally:
            backend.close()
    if unresolved:
        print(f"cleanup blocked: {unresolved} retired project-path reference(s) remain")
        return 3
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["apply"])
    parser.add_argument("--db", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--target-root", required=True)
    parser.add_argument("--require-target-exists", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--opencode-db")
    args = parser.parse_args()
    raise SystemExit(apply(args))


if __name__ == "__main__":
    main()
