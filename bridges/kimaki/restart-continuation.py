#!/usr/bin/env python3
"""Bounded, secret-free restart continuation for managed Kimaki services."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


VERSION = 1
MAX_TTL = 900
ROUTE_RE = re.compile(r"^[0-9]{17,20}$")
SESSION_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
UNIT_RE = re.compile(r"^kimaki(?:-[A-Za-z0-9_.@-]+)?\.service$")
CHECKS = ("bridge_status", "managed_plugins", "startup_warnings")
NEXT_ACTION = "resume_verification"


def emit(status: str, **fields: object) -> None:
    print(json.dumps({"status": status, **fields}, sort_keys=True, separators=(",", ":")))


def state_dir(data_dir: str) -> Path:
    return Path(data_dir).expanduser().resolve() / "kimaki-config" / "restart-continuation"


def site_identity(site_path: str) -> tuple[str, str]:
    resolved = str(Path(site_path).expanduser().resolve())
    digest = hashlib.sha256(resolved.encode("utf-8")).hexdigest()[:24]
    return resolved, digest


def write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def read_record(path: Path) -> dict[str, object]:
    if path.stat().st_size > 4096:
        raise ValueError("record_too_large")
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("record_not_object")
    return value


def validate_record(record: dict[str, object], site_path: str, now: int) -> str | None:
    resolved_site, identity = site_identity(site_path)
    route = record.get("route")
    site = record.get("site")
    upgrade = record.get("upgrade")
    if record.get("version") != VERSION:
        return "unsupported_version"
    if not isinstance(record.get("id"), str) or not SESSION_RE.fullmatch(str(record["id"])):
        return "invalid_id"
    if not isinstance(site, dict) or site.get("path") != resolved_site or site.get("id") != identity:
        return "site_mismatch"
    if not isinstance(route, dict) or route.get("kind") != "discord_thread":
        return "invalid_route"
    if not isinstance(route.get("id"), str) or not ROUTE_RE.fullmatch(str(route["id"])):
        return "invalid_route"
    session_id = route.get("session_id")
    if session_id is not None and (not isinstance(session_id, str) or not SESSION_RE.fullmatch(session_id)):
        return "invalid_session"
    created = record.get("created_at")
    expires = record.get("expires_at")
    if not isinstance(created, int) or not isinstance(expires, int) or expires <= created or expires - created > MAX_TTL:
        return "invalid_ttl"
    if now > expires:
        return "expired"
    if not isinstance(upgrade, dict) or upgrade.get("status") != "success":
        return "upgrade_not_successful"
    if record.get("checks") != list(CHECKS) or record.get("next_action") != NEXT_ACTION:
        return "invalid_action"
    return None


def recovery_argv(args: argparse.Namespace) -> list[str]:
    return [
        str(Path(__file__).resolve()),
        "restart-worker",
        "--mode",
        args.mode,
        "--target",
        args.target,
        "--data-dir",
        args.data_dir,
    ]


def prepare(args: argparse.Namespace) -> int:
    route_id = args.route_id or os.environ.get("KIMAKI_THREAD_ID", "")
    session_id = args.session_id or os.environ.get("KIMAKI_SESSION_ID")
    if not ROUTE_RE.fullmatch(route_id):
        emit("rejected", reason="missing_or_invalid_thread_route")
        return 2
    if session_id and not SESSION_RE.fullmatch(session_id):
        emit("rejected", reason="invalid_session_id")
        return 2

    directory = state_dir(args.data_dir)
    pending = directory / "pending.json"
    now = args.now if args.now is not None else int(time.time())
    if pending.exists():
        try:
            existing = read_record(pending)
            invalid = validate_record(existing, args.site_path, now)
        except (OSError, ValueError, json.JSONDecodeError):
            invalid = "invalid_record"
        if invalid is None:
            emit("already_pending", continuation_id=existing["id"], recovery_command=recovery_argv(args))
            return 0
        os.replace(pending, directory / "rejected.json")

    resolved_site, identity = site_identity(args.site_path)
    continuation_id = args.continuation_id or str(uuid.uuid4())
    if not SESSION_RE.fullmatch(continuation_id):
        emit("rejected", reason="invalid_continuation_id")
        return 2
    record: dict[str, object] = {
        "version": VERSION,
        "id": continuation_id,
        "created_at": now,
        "expires_at": now + args.ttl,
        "site": {"path": resolved_site, "id": identity},
        "route": {"kind": "discord_thread", "id": route_id, "session_id": session_id},
        "upgrade": {"status": "success"},
        "checks": list(CHECKS),
        "next_action": NEXT_ACTION,
    }
    write_json(pending, record)

    worker = recovery_argv(args)
    if args.foreground:
        emit("handoff_accepted", continuation_id=continuation_id, recovery_command=worker)
        return subprocess.call(worker)
    subprocess.Popen(
        worker,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    emit("handoff_accepted", continuation_id=continuation_id, recovery_command=worker)
    return 0


def restart_worker(args: argparse.Namespace) -> int:
    directory = state_dir(args.data_dir)
    status_file = directory / "restart-status.json"
    recovery = recovery_argv(args)
    if args.delay:
        time.sleep(args.delay)
    if args.mode == "launchd":
        target = str(Path(args.target).expanduser().resolve())
        if not target.endswith(".plist"):
            write_json(status_file, {"status": "rejected", "reason": "invalid_launchd_target", "recovery_command": recovery})
            return 2
        domain = f"gui/{os.getuid()}"
        subprocess.run(["launchctl", "bootout", domain, target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        command = ["launchctl", "bootstrap", domain, target]
        failed_phase = "bootstrap"
    else:
        if not UNIT_RE.fullmatch(args.target):
            write_json(status_file, {"status": "rejected", "reason": "invalid_systemd_unit", "recovery_command": recovery})
            return 2
        command = ["systemctl", "restart", args.target]
        failed_phase = "restart"
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    status = "ok" if result.returncode == 0 else "restart_failed"
    value: dict[str, object] = {"status": status, "mode": args.mode, "target": args.target}
    if result.returncode != 0:
        value.update({"phase": failed_phase, "exit_code": result.returncode, "recovery_command": recovery})
    write_json(status_file, value)
    return result.returncode


def consume(args: argparse.Namespace) -> int:
    directory = state_dir(args.data_dir)
    pending = directory / "pending.json"
    claim = directory / "claimed.json"
    consumed = directory / "consumed.json"
    status_file = directory / "resume-status.json"
    if not pending.exists():
        emit("no_pending")
        return 0
    try:
        os.replace(pending, claim)
    except FileNotFoundError:
        emit("already_claimed")
        return 0
    try:
        record = read_record(claim)
        now = args.now if args.now is not None else int(time.time())
        invalid = validate_record(record, args.site_path, now)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        invalid = str(error) or "invalid_record"
        record = {"id": "unknown"}
    if invalid is not None:
        os.replace(claim, directory / "rejected.json")
        write_json(status_file, {"status": "rejected", "reason": invalid, "continuation_id": record.get("id", "unknown")})
        emit("rejected", reason=invalid)
        return 0

    # Commit consumption before dispatch. This deliberately provides at-most-once
    # delivery: an ambiguous client failure is never retried into a duplicate reply.
    os.replace(claim, consumed)
    write_json(status_file, {"status": "dispatching", "continuation_id": record["id"]})
    if args.delay:
        time.sleep(args.delay)
    route = record["route"]
    prompt = (
        "Managed upgrade restart continuation. Verify the Kimaki bridge status, managed OpenCode "
        "plugins, and startup warnings, then continue the prior tracked workflow without rerunning "
        f"upgrade mutations. Continuation ID: {record['id']}"
    )
    result = subprocess.run(
        [args.kimaki_bin, "send", "--channel", str(route["id"]), "--prompt", prompt],
        cwd=str(record["site"]["path"]),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    status = "resumed" if result.returncode == 0 else "dispatch_failed"
    write_json(
        status_file,
        {"status": status, "continuation_id": record["id"], "exit_code": result.returncode},
    )
    emit(status, continuation_id=record["id"])
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    restart = commands.add_parser("restart")
    restart.add_argument("--mode", choices=("launchd", "systemd"), required=True)
    restart.add_argument("--target", required=True)
    restart.add_argument("--site-path", required=True)
    restart.add_argument("--data-dir", required=True)
    restart.add_argument("--route-id")
    restart.add_argument("--session-id")
    restart.add_argument("--ttl", type=int, choices=range(1, MAX_TTL + 1), default=300)
    restart.add_argument("--continuation-id", help=argparse.SUPPRESS)
    restart.add_argument("--now", type=int, help=argparse.SUPPRESS)
    restart.add_argument("--foreground", action="store_true", help=argparse.SUPPRESS)
    restart.set_defaults(handler=prepare)

    worker = commands.add_parser("restart-worker")
    worker.add_argument("--mode", choices=("launchd", "systemd"), required=True)
    worker.add_argument("--target", required=True)
    worker.add_argument("--data-dir", required=True)
    worker.add_argument("--delay", type=float, default=0.5)
    worker.set_defaults(handler=restart_worker)

    resume = commands.add_parser("consume")
    resume.add_argument("--site-path", required=True)
    resume.add_argument("--data-dir", required=True)
    resume.add_argument("--kimaki-bin", default="kimaki")
    resume.add_argument("--delay", type=float, default=8.0)
    resume.add_argument("--now", type=int, help=argparse.SUPPRESS)
    resume.set_defaults(handler=consume)
    return result


if __name__ == "__main__":
    arguments = parser().parse_args()
    sys.exit(arguments.handler(arguments))
