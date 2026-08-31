#!/bin/bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
node "$ROOT_DIR/scripts/validate-dmc-migration-inventory.mjs"
