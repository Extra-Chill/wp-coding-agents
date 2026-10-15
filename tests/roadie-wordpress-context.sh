#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
node "$root/tests/roadie-wordpress-context.mjs"
python3 "$root/tests/roadie-wordpress-context.py"
