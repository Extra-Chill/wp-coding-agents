#!/usr/bin/env python3
"""Execute the environment-supplied external WordPress control transport."""

import json
import os
import sys


def fail(message: str) -> None:
    print(f"wp-control: {message}", file=sys.stderr)
    raise SystemExit(2)


try:
    transport = json.loads(os.environ.get("WP_CONTROL_TRANSPORT_JSON", ""))
except json.JSONDecodeError:
    fail("WP_CONTROL_TRANSPORT_JSON is not valid JSON")

if not isinstance(transport, list) or not transport or any(not isinstance(value, str) or not value for value in transport):
    fail("WP_CONTROL_TRANSPORT_JSON must be a non-empty argv array")

profile_path = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "wordpress.json")
try:
    with open(profile_path, encoding="utf-8") as stream:
        profile = json.load(stream)
except (OSError, json.JSONDecodeError):
    profile = {}

wordpress_path = os.environ.get("WORDPRESS_PATH", "") or profile.get("wordpress_path", "")
if not wordpress_path:
    fail("WORDPRESS_PATH is required")

command = [*transport, *sys.argv[1:]]
wordpress_user = os.environ.get("WORDPRESS_USER", "") or profile.get("wordpress_user", "")
if wordpress_user:
    command.append(f"--user={wordpress_user}")
command.append(f"--path={wordpress_path}")
os.execvpe(command[0], command, os.environ)
