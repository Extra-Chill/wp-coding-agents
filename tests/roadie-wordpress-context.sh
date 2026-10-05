#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
node "$root/tests/roadie-wordpress-context.mjs"
php "$root/tests/roadie-wordpress-context.php"
python3 "$root/tests/roadie-wordpress-context.py"
php -l "$root/bridges/roadie/roadie-plugins/wordpress-context.php"
