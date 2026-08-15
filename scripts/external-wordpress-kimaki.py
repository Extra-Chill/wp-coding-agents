#!/usr/bin/env python3
"""Start Kimaki with the non-secret external WordPress site mapping."""

import json
import os
import sys


if not os.environ.get("WP_CONTROL_TRANSPORT_JSON"):
    print("kimaki: WP_CONTROL_TRANSPORT_JSON is required", file=sys.stderr)
    raise SystemExit(2)

profile_path = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "wordpress.json")
try:
    with open(profile_path, encoding="utf-8") as stream:
        profile = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    print(f"kimaki: external WordPress profile is unavailable: {error}", file=sys.stderr)
    raise SystemExit(2)

environment = os.environ.copy()
environment["EXTERNAL_WORDPRESS"] = "true"
environment["WORDPRESS_PATH"] = profile.get("wordpress_path", "")
environment["WORDPRESS_USER"] = profile.get("wordpress_user", "")
os.execvpe("kimaki", ["kimaki", *sys.argv[1:]], environment)
