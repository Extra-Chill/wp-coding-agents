#!/usr/bin/env python3
"""Root-owned DMC process inspection adapter. It accepts only one path on stdin."""
import json
import os
import stat
import sys
import syslog
from pathlib import Path

def fail(message):
    print(json.dumps({"status": "rejected", "error": message}))
    raise SystemExit(2)

if len(sys.argv) != 2:
    fail("exactly one capability profile is required")
CONFIG_ROOT = Path("/etc/wp-coding-agents/systems-capabilities")
requested_config = Path(sys.argv[1])
if os.geteuid() == 0:
    try:
        if requested_config.parent != CONFIG_ROOT or requested_config.suffix != ".json":
            fail("capability profile is outside the managed configuration root")
        config_stat = requested_config.stat()
        if config_stat.st_uid != 0 or config_stat.st_mode & 0o022:
            fail("capability profile ownership or mode is unsafe")
    except OSError:
        fail("capability profile is unavailable")
CONFIG = requested_config
candidate = sys.stdin.readline().strip()
if not candidate or sys.stdin.read().strip():
    fail("exactly one candidate path is required on stdin")
try:
    config = json.loads(Path(CONFIG).read_text())
    roots = [Path(root).resolve() for root in config["workspace_roots"]]
    path = Path(candidate).resolve(strict=True)
except (OSError, ValueError, KeyError, json.JSONDecodeError):
    fail("candidate or configured workspace roots are invalid")
if not roots:
    fail("no configured DMC workspace roots are available")
if not any(path != root and root in path.parents for root in roots):
    fail("candidate path is outside configured DMC workspace roots")

if not Path("/proc").is_dir():
    print(json.dumps({"status": "unavailable", "error": "process inspection requires Linux /proc"}))
    raise SystemExit(3)

O_PATH = getattr(os, "O_PATH", os.O_RDONLY)
DIRECTORY_FLAGS = O_PATH | os.O_DIRECTORY
candidate_identity = (path.stat().st_dev, path.stat().st_ino)

def process_still_exists(entry):
    return entry.is_dir()

def process_is_zombie(entry):
    try:
        fields = (entry / "stat").read_text().split()
        return len(fields) > 2 and fields[2] == "Z"
    except OSError:
        return not process_still_exists(entry)

def directory_is_within_candidate(directory_fd):
    current = os.dup(directory_fd)
    try:
        for _ in range(512):
            current_stat = os.fstat(current)
            if (current_stat.st_dev, current_stat.st_ino) == candidate_identity:
                return True
            parent = os.open("..", DIRECTORY_FLAGS, dir_fd=current)
            parent_stat = os.fstat(parent)
            if (parent_stat.st_dev, parent_stat.st_ino) == (current_stat.st_dev, current_stat.st_ino):
                os.close(parent)
                return False
            os.close(current)
            current = parent
        raise OSError("directory ancestry exceeded safety bound")
    finally:
        os.close(current)

def reference_is_within_candidate(entry, reference):
    reference_stat = reference.stat()
    if stat.S_ISDIR(reference_stat.st_mode):
        directory_fd = os.open(reference, DIRECTORY_FLAGS)
    else:
        target = os.readlink(reference)
        if not target.startswith("/"):
            return False
        target = target.removesuffix(" (deleted)")
        parent = os.path.dirname(target)
        directory_fd = os.open(str(entry / "root") + parent, DIRECTORY_FLAGS)
    try:
        return directory_is_within_candidate(directory_fd)
    finally:
        os.close(directory_fd)

processes = []
incomplete = []
for entry in Path("/proc").iterdir():
    if not entry.name.isdigit():
        continue
    pid = entry.name
    matches = []
    try:
        command = (entry / "comm").read_text().strip()
    except OSError:
        command = ""
    try:
        if reference_is_within_candidate(entry, entry / "cwd"):
            matches.append("cwd")
    except (FileNotFoundError, ProcessLookupError):
        if process_still_exists(entry) and not process_is_zombie(entry):
            incomplete.append({"pid": int(pid), "resource": "cwd"})
    except (OSError, PermissionError):
        if process_still_exists(entry) and not process_is_zombie(entry):
            incomplete.append({"pid": int(pid), "resource": "cwd"})
    try:
        fd_entries = list((entry / "fd").iterdir())
    except (FileNotFoundError, ProcessLookupError):
        fd_entries = []
        if process_still_exists(entry) and not process_is_zombie(entry):
            incomplete.append({"pid": int(pid), "resource": "fd"})
    except (OSError, PermissionError):
        fd_entries = []
        if process_still_exists(entry) and not process_is_zombie(entry):
            incomplete.append({"pid": int(pid), "resource": "fd"})
    for fd in fd_entries:
        try:
            if reference_is_within_candidate(entry, fd):
                matches.append("open_file")
                break
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (OSError, PermissionError):
            # The descriptor itself is known to be unreadable. Probing it again
            # can raise the same PermissionError and escape this handler.
            if process_still_exists(entry) and not process_is_zombie(entry):
                incomplete.append({"pid": int(pid), "resource": "fd"})
                break
    if matches:
        for match_type in sorted(set(matches)):
            processes.append({"pid": int(pid), "command": command, "match_type": match_type, "path": str(path)})

if incomplete:
    syslog.openlog("wp-coding-agents-dmc-process-inspect", syslog.LOG_PID, syslog.LOG_AUTHPRIV)
    syslog.syslog(syslog.LOG_WARNING, "incomplete process inspection candidate=%s unreadable=%d" % (path, len(incomplete)))
    print(json.dumps({"status": "unavailable", "path": str(path), "error": "process inspection was incomplete", "unreadable_count": len(incomplete)}))
    raise SystemExit(3)

syslog.openlog("wp-coding-agents-dmc-process-inspect", syslog.LOG_PID, syslog.LOG_AUTHPRIV)
syslog.syslog(syslog.LOG_INFO, "inspected configured DMC workspace candidate=%s matches=%d" % (path, len(processes)))
print(json.dumps({"status": "available", "path": str(path), "processes": processes}, sort_keys=True))
