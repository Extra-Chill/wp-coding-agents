#!/bin/bash
# tests/homeboy-dmc-provider.sh — Homeboy DMC worktree provider config.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/wordpress.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy.sh"

TMP="$(mktemp -d)"
ORIGINAL_PATH="$PATH"
trap 'rm -rf "$TMP"' EXIT

SITE_PATH="$TMP/site"
WP_CMD="wp"
WP_ROOT_FLAG=""
IS_STUDIO=true
LOCAL_MODE=true
HOMEBOY_MODE="auto"
WITH_HOMEBOY=false
mkdir -p "$SITE_PATH"
touch "$SITE_PATH/wp-config.php"

assert_contains() {
  local needle="$1" file="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL: expected '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -qF -- "$needle" "$file"; then
    echo "FAIL: unexpected '$needle' in $file"
    cat "$file"
    exit 1
  fi
}

assert_provider_contract() {
  python3 - "$1" "$SITE_PATH" <<'PY'
import json
import sys

line = open(sys.argv[1], encoding="utf-8").read().strip()
_, payload = line.split("|", 1)
try:
    provider = json.loads(payload)
except json.JSONDecodeError as error:
    raise SystemExit(f"FAIL: provider config is not valid JSON: {error}: {payload!r}")
site_path = sys.argv[2]
prefix = ["studio", "wp", "datamachine-code", "workspace"]
expected_commands = {
    "resolve": prefix + ["worktree", "get", "{handle}", "--format=json", f"--path={site_path}"],
    "apply": prefix + ["promotion-apply", "{handle}", f"--path={site_path}"],
    "list": prefix + ["worktree", "list", "--with-status", "--format=json", f"--path={site_path}"],
    "cleanup_preview": prefix + ["cleanup", "safe", "--dry-run", "--format=json", f"--path={site_path}"],
    "cleanup_apply": prefix + ["cleanup", "safe", "--format=json", f"--path={site_path}"],
}
if provider.get("enabled") is not True or provider.get("kind") != "command" or provider.get("apply_enabled") is not True:
    raise SystemExit("FAIL: provider enablement fields changed")
if provider.get("commands") != expected_commands:
    raise SystemExit(f"FAIL: provider commands changed: {provider.get('commands')!r}")
expected = {
    "items": "$",
    "handle": "$.handle",
    "path": "$.path",
    "branch": "$.branch",
    "dirty": "$.safety.dirty",
    "unpushed": "$.safety.unpushed",
    "primary": "$.safety.primary",
}
if provider.get("list_result_mapping") != expected:
    raise SystemExit("FAIL: provider list_result_mapping does not match the DMC safety output")
PY
}

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/homeboy" <<'SH'
#!/bin/sh
if [ "$1 $2" = "config set" ]; then
  printf '%s|%s\n' "$3" "$4" >> "$HOMEBOY_CONFIG_LOG"
  exit 0
fi
exit 2
SH
chmod +x "$FAKE_BIN/homeboy"

cat > "$FAKE_BIN/studio" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUDIO_LOG"
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree list" ]; then
  printf '{"success":true,"data":[]}\n'
  exit 0
fi
exit 2
SH
chmod +x "$FAKE_BIN/studio"

PATH="$FAKE_BIN:$PATH"
HOMEBOY_CONFIG_LOG="$TMP/homeboy-config.log"
STUDIO_LOG="$TMP/studio.log"
export HOMEBOY_CONFIG_LOG STUDIO_LOG

# macOS ships Bash 3.2, which has no mapfile/readarray builtin. Disable it
# when the test runs under newer Bash so this path stays portable.
enable -n mapfile 2>/dev/null || true

NO_FLAG_COMMAND="$(SITE_PATH= WP_ROOT_FLAG= homeboy_dmc_command_json apply)"
if [ "$NO_FLAG_COMMAND" != '["studio","wp","datamachine-code","workspace","promotion-apply","{handle}"]' ]; then
  echo "FAIL: empty optional WP flags changed the apply argv: $NO_FLAG_COMMAND"
  exit 1
fi

DRY_RUN=true
configure_homeboy_dmc_worktree_provider > "$TMP/dry-run.log"

assert_contains "homeboy config set /worktree_providers/dmc '{\"enabled\":true,\"kind\":\"command\",\"apply_enabled\":true" "$TMP/dry-run.log"
assert_contains "\"resolve\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"get\",\"{handle}\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"apply\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"promotion-apply\",\"{handle}\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"list\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"list\",\"--with-status\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"cleanup_preview\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"cleanup\",\"safe\",\"--dry-run\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"cleanup_apply\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"cleanup\",\"safe\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
if [ -f "$HOMEBOY_CONFIG_LOG" ]; then
  echo "FAIL: dry-run should not call homeboy config set"
  cat "$HOMEBOY_CONFIG_LOG"
  exit 1
fi

DRY_RUN=false
configure_homeboy_dmc_worktree_provider > "$TMP/apply.log"

assert_contains "wp datamachine-code workspace worktree list --format=json --path=$SITE_PATH" "$STUDIO_LOG"
assert_contains "/worktree_providers/dmc|{\"enabled\":true,\"kind\":\"command\",\"apply_enabled\":true" "$HOMEBOY_CONFIG_LOG"
assert_provider_contract "$HOMEBOY_CONFIG_LOG"

HOMEBOY_MODE="disabled"
HOMEBOY_CONFIG_LOG="$TMP/disabled-homeboy-config.log"
export HOMEBOY_CONFIG_LOG
configure_homeboy_dmc_worktree_provider > "$TMP/disabled.log"
assert_contains "Skipping Homeboy DMC worktree provider setup (--no-homeboy)" "$TMP/disabled.log"
if [ -f "$HOMEBOY_CONFIG_LOG" ]; then
  echo "FAIL: disabled mode should not call homeboy config set"
  cat "$HOMEBOY_CONFIG_LOG"
  exit 1
fi

HOMEBOY_MODE="auto"
SANDBIN="$TMP/sandbin"
mkdir -p "$SANDBIN"
for tool in grep cat rm; do
  resolved="$(PATH="$ORIGINAL_PATH" command -v "$tool" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$SANDBIN/$tool"
done
PATH="$SANDBIN"
configure_homeboy_dmc_worktree_provider > "$TMP/absent.log"
assert_contains "Homeboy is not callable from this setup/runtime PATH; skipping DMC worktree provider setup." "$TMP/absent.log"
assert_not_contains "config set" "$TMP/absent.log"

echo "OK: Homeboy DMC worktree provider config respects dry-run and optional skips"
