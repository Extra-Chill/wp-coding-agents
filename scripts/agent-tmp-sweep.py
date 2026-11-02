#!/usr/bin/python3
"""Conservative /tmp backstop; run as the non-root agent user.

Validate whole trees before removal. Descriptor-relative operations never
follow symlinks or cross mounts, even if an agent renames entries mid-sweep.
"""
import os
from pathlib import Path
import re
import stat
import sys
import time


def age_seconds(value):
    match = re.fullmatch(r"([1-9][0-9]*)([smhdw])", value)
    if not match:
        raise ValueError("sweep age must be a positive integer with s/m/h/d/w suffix")
    return int(match[1]) * dict(s=1, m=60, h=3600, d=86400, w=604800)[match[2]]


def sweep(root, uid, age, now=None):
    if uid == 0 or uid != os.geteuid():
        raise ValueError("sweep must run as the non-root service user")
    cutoff = (time.time() if now is None else now) - age
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    root_fd = os.open(root, flags)
    device = os.fstat(root_fd).st_dev

    def collect(parent, name):
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (info.st_uid != uid or info.st_dev != device
                or name.startswith("systemd-private-")
                or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))
                or max(info.st_atime, info.st_mtime, info.st_ctime) >= cutoff):
            raise ValueError("protected or recent entry")
        children = []
        if stat.S_ISDIR(info.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if os.fstat(fd).st_ino != info.st_ino:
                    raise ValueError("entry changed")
                children = [(child, collect(fd, child)) for child in os.listdir(fd)]
            finally:
                os.close(fd)
        return info, children

    def remove(parent, name, tree):
        before, children = tree
        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (current.st_dev, current.st_ino, current.st_uid, current.st_mode) != (
                before.st_dev, before.st_ino, uid, before.st_mode):
            raise ValueError("entry changed")
        if stat.S_ISDIR(current.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if os.fstat(fd).st_ino != before.st_ino:
                    raise ValueError("entry changed")
                for child, subtree in children:
                    remove(fd, child, subtree)
            finally:
                os.close(fd)
            os.rmdir(name, dir_fd=parent)
        else:
            if max(current.st_atime, current.st_mtime, current.st_ctime) >= cutoff:
                raise ValueError("entry became active")
            os.unlink(name, dir_fd=parent)

    try:
        for name in os.listdir(root_fd):
            try:
                remove(root_fd, name, collect(root_fd, name))
            except (OSError, ValueError):
                continue
    finally:
        os.close(root_fd)


if __name__ == "__main__":
    sweep(Path("/tmp"), os.geteuid(), age_seconds(sys.argv[1]))
