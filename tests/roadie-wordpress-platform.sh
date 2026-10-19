#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
node "$root/tests/roadie-wordpress-platform.mjs"
node "$root/tests/roadie-wordpress-runtime-entry.mjs"
