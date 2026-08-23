#!/bin/bash

dmc_managed_release_integration_sync() {
  local file="$SITE_PATH/wp-content/mu-plugins/wp-coding-agents-dmc-managed-release.php"
  local template="$SCRIPT_DIR/templates/wp-coding-agents-dmc-managed-release.php"
  [ -f "$template" ] || { warn "Missing DMC managed-release integration template"; return 1; }
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would sync DMC managed-release/runtime-doctor integration to $file"
    return 0
  fi
  mkdir -p "${file%/*}"
  local rendered
  rendered="$(WP_CODING_AGENTS_UPGRADE_SCRIPT="$SCRIPT_DIR/upgrade.sh" python3 - "$template" <<'PY'
import os
import pathlib
import sys

value = os.environ['WP_CODING_AGENTS_UPGRADE_SCRIPT'].replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n').replace('\r', '\\r')
print(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').replace('@WP_CODING_AGENTS_UPGRADE_SCRIPT@', value), end='')
PY
)"
  if [ ! -f "$file" ] || ! printf '%s\n' "$rendered" | cmp -s - "$file"; then
    printf '%s\n' "$rendered" > "$file"
    UPDATED_ITEMS+=("DMC managed-release/runtime-doctor integration")
  fi
  service_file_normalize_perms "$file"
}
