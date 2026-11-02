#!/usr/bin/env python3
"""Behavior checks with a disposable temp root, never the real /tmp."""
import importlib.util
import os
from pathlib import Path
import pwd
import socket
import subprocess
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location(
    "sweep", Path(__file__).resolve().parents[1] / "scripts/agent-tmp-sweep.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def check(root):
    uid = os.geteuid()
    assert uid != 0
    stale = root / "stale-clone"
    stale.mkdir()
    (stale / "target").mkdir()
    (stale / "target" / "binary").write_text("build")
    (root / "stale-file").write_text("scratch")
    (root / "systemd-private-test").mkdir()
    (root / "link").symlink_to(stale, target_is_directory=True)
    sock = socket.socket(socket.AF_UNIX)
    cwd = os.getcwd()
    try:
        os.chdir(root)
        sock.bind("socket")
    finally:
        os.chdir(cwd)
    mixed = root / "mixed"
    mixed.mkdir()
    (mixed / "socket").symlink_to(root / "socket")
    now = time.time()
    # Future reference time ages ctime too, without sleeping for three days.
    future = now + 5 * 86400
    active = root / "active"
    active.mkdir()
    (active / "recent").write_text("in use")
    os.utime(active / "recent", (future, future))
    module.sweep(root, uid, 3 * 86400, now=future)
    assert not stale.exists()
    assert not (root / "stale-file").exists()
    for name in ("systemd-private-test", "link", "socket", "mixed", "active"):
        assert (root / name).exists() or (root / name).is_symlink(), name
    if (root / "foreign").exists():
        assert (root / "foreign" / "keep").read_text() == "foreign"
    sock.close()


assert module.age_seconds("3d") == 259200
for invalid in ("0d", "-3d", "3d; rm", "never", "3"):
    try:
        module.age_seconds(invalid)
        raise AssertionError(invalid)
    except ValueError:
        pass

if len(sys.argv) > 1:
    check(Path(sys.argv[1]))
else:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        if os.geteuid() == 0:
            try:
                module.sweep(root, 0, 1)
                raise AssertionError("root sweep allowed")
            except ValueError:
                pass
            user = pwd.getpwnam("nobody")
            foreign = root / "foreign"
            foreign.mkdir()
            (foreign / "keep").write_text("foreign")
            os.chown(root, user.pw_uid, user.pw_gid)
            # Run a copy: the repository can be inside a root-only checkout.
            runner = root / "runner.py"
            runner.write_text(Path(__file__).read_text().replace(
                'Path(__file__).resolve().parents[1] / "scripts/agent-tmp-sweep.py"',
                'Path(__file__).parent / "sweep.py"'))
            (root / "sweep.py").write_text(Path(spec.origin).read_text())
            def drop():
                os.setgroups([])
                os.setgid(user.pw_gid)
                os.setuid(user.pw_uid)
            subprocess.run([sys.executable, str(runner), str(root)],
                           preexec_fn=drop, check=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        else:
            check(root)
    print("PASS: tests/agent-tmp-sweep.py")
