#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
node "$root/tests/roadie-fork-workspace.mjs"
