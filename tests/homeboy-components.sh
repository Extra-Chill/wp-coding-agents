#!/bin/bash
# Homeboy components derive only from explicit workspace repositories.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/source-policy.sh"
source "$ROOT_DIR/lib/homeboy.sh"

SITE_PATH="$TMP/site"
PRIMARY="$TMP/primary"
WORKTREE="$TMP/primary@task"
MISSING="$TMP/missing"
mkdir -p "$SITE_PATH" "$PRIMARY" "$WORKTREE" "$TMP/bin"
git -C "$PRIMARY" init -q
printf '{"id":"site"}\n' > "$SITE_PATH/homeboy.json"

cat > "$TMP/bin/homeboy" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HOMEBOY_LOG"
exit 0
SH
chmod +x "$TMP/bin/homeboy"

PATH="$TMP/bin:$PATH"
export PATH
HOMEBOY_LOG="$TMP/homeboy.log"
export HOMEBOY_LOG
WORKSPACE_REPOSITORIES="$PRIMARY:$WORKTREE:$MISSING:$SITE_PATH"
SOURCE_MODE=workspace
DRY_RUN=false
log() { :; }
warn() { :; }

sync_homeboy_project_components
grep -qxF "project components attach-path site $PRIMARY" "$HOMEBOY_LOG"
if grep -Fq "$WORKTREE" "$HOMEBOY_LOG" || grep -Fq "$MISSING" "$HOMEBOY_LOG" || grep -Fq "$SITE_PATH" "$HOMEBOY_LOG"; then
  echo "FAIL: Homeboy attached a non-primary declared path" >&2
  exit 1
fi

echo "PASS: Homeboy components use explicit repository authority"
