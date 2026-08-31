#!/usr/bin/env python3
"""Read-only discovery and audit surface for managed systems capabilities."""
import json
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
    print(json.dumps({"profiles": profiles}, sort_keys=True))

if len(sys.argv) != 2 or sys.argv[1] != "status":
    raise SystemExit("Usage: wp-coding-agents-systems-capabilities status")
status()
