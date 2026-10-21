#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
php -l "$ROOT/templates/wp-coding-agents-onboarding.php"
php "$ROOT/tests/onboarding-intro.php"
bash "$ROOT/tests/cli-transport-install.sh"
php "$ROOT/tests/smoke-cli-transport.php"
node "$ROOT/tests/roadie-wordpress-context.mjs"
