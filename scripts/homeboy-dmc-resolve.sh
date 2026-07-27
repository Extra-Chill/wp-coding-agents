#!/bin/bash
# Convert only DMC's typed missing-worktree result into Homeboy's configured
# absence status; preserve every other provider failure unchanged.
set -u

NOT_FOUND_EXIT=42
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT

"$@" >"$stdout_file" 2>"$stderr_file"
status=$?

if [ "$status" -eq 0 ]; then
  cat "$stdout_file"
  cat "$stderr_file" >&2
  exit 0
fi

cat "$stdout_file"
cat "$stderr_file" >&2

if python3 - "$stdout_file" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

raise SystemExit(0 if payload.get("error", {}).get("code") == "worktree_not_found" else 1)
PY
then
  exit "$NOT_FOUND_EXIT"
fi

exit "$status"
