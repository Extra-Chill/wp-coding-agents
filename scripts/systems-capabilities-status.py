#!/usr/bin/env python3
"""Read-only discovery and audit surface for managed systems capabilities."""
import json
import subprocess
import sys
from pathlib import Path

PROFILE_ROOT = Path("/etc/wp-coding-agents/systems-capabilities")

def status():
    profiles = []
    for file in sorted(PROFILE_ROOT.glob("*.json")):
        try:
            profiles.append(json.loads(file.read_text()))
        except (OSError, json.JSONDecodeError):
            profiles.append({"profile_file": str(file), "status": "invalid"})
    print(json.dumps({"profiles": profiles, "audit_command": "wp-coding-agents-systems-capabilities audit"}, sort_keys=True))

def audit():
    try:
        result = subprocess.run(["journalctl", "-t", "wp-coding-agents-process-inspect", "--no-pager", "-o", "short-iso"], text=True, capture_output=True)
    except OSError as error:
        print(json.dumps({"status": "unavailable", "entries": [], "error": str(error)}))
        return
    print(json.dumps({"status": "ok" if result.returncode == 0 else "unavailable", "entries": result.stdout.splitlines()}))

if len(sys.argv) != 2 or sys.argv[1] not in ("status", "audit"):
    raise SystemExit("Usage: wp-coding-agents-systems-capabilities <status|audit>")
{"status": status, "audit": audit}[sys.argv[1]]()
