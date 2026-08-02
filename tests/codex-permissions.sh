#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SITE_PATH="$TMP/site"
export DRY_RUN=false
mkdir -p "$SITE_PATH/.codex" "$TMP/bin"

cat > "$TMP/bin/codex" <<'SH'
#!/bin/sh
echo "codex-cli 0.142.5"
SH
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

cat > "$SITE_PATH/.codex/config.toml" <<'TOML'
model = "gpt-5.4"
TOML

UPDATED_ITEMS=()
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/source-policy.sh"
POSTURE="${POSTURE:-engineering}"
source "$SCRIPT_DIR/runtimes/codex.sh"

runtime_generate_config

CONFIG="$SITE_PATH/.codex/config.toml"
grep -Fq 'default_permissions = "wp-coding-agents-wordpress"' "$CONFIG"
grep -Fq '"wp-content/plugins" = "read"' "$CONFIG"
grep -Fq '"wp-content/themes" = "read"' "$CONFIG"
grep -Fq '"wp-includes" = "read"' "$CONFIG"
grep -Fq 'model = "gpt-5.4"' "$CONFIG"

HASH_BEFORE=$(md5 -q "$CONFIG" 2>/dev/null || md5sum "$CONFIG" | cut -d' ' -f1)
runtime_generate_config
HASH_AFTER=$(md5 -q "$CONFIG" 2>/dev/null || md5sum "$CONFIG" | cut -d' ' -f1)
[ "$HASH_BEFORE" = "$HASH_AFTER" ]

SITE_PATH="$TMP/conflicting-site"
mkdir -p "$SITE_PATH/.codex"
printf 'sandbox_mode = "workspace-write"\n' > "$SITE_PATH/.codex/config.toml"
runtime_generate_config
if grep -Fq 'WP_CODING_AGENTS_WORDPRESS_PERMISSIONS' "$SITE_PATH/.codex/config.toml"; then
  echo "FAIL: Codex managed permissions replaced a user sandbox policy"
  exit 1
fi

SITE_PATH="$TMP/conflicting-table-site"
mkdir -p "$SITE_PATH/.codex"
printf '[sandbox_workspace_write]\nnetwork_access = false\n' > "$SITE_PATH/.codex/config.toml"
runtime_generate_config
if grep -Fq 'WP_CODING_AGENTS_WORDPRESS_PERMISSIONS' "$SITE_PATH/.codex/config.toml"; then
  echo "FAIL: Codex managed permissions mixed with sandbox_workspace_write"
  exit 1
fi

echo "PASS: Codex WordPress source permissions"
