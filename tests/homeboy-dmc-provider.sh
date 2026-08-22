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
DM_WORKSPACE_DIR="$TMP/workspace"
WP_CMD="wp"
WP_ROOT_FLAG=""
IS_STUDIO=true
LOCAL_MODE=true
HOMEBOY_MODE="auto"
WITH_HOMEBOY=false
mkdir -p "$SITE_PATH/wp-content/plugins/data-machine-code/bin" "$DM_WORKSPACE_DIR"
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

assert_provider_mapping() {
  python3 - "$1" <<'PY'
import json
import sys

line = open(sys.argv[1], encoding="utf-8").read().strip()
_, payload = line.split("|", 1)
try:
    provider = json.loads(payload)
except json.JSONDecodeError as error:
    raise SystemExit(f"FAIL: provider config is not valid JSON: {error}: {payload!r}")
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

assert_provider_contract() {
  python3 - "$1" "$2" "$3" "$DM_WORKSPACE_DIR" <<'PY'
import json
import sys

line = open(sys.argv[1], encoding="utf-8").read().strip()
_, payload = line.split("|", 1)
provider = json.loads(payload)
commands = provider["commands"]
expected_resolve = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "resolve", f"{sys.argv[3]}/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider", sys.argv[4], "{handle}"]
expected_resolve_path = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "resolve", f"{sys.argv[3]}/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider", sys.argv[4], "{path}"]
expected_ensure = ["studio", "wp", "datamachine-code", "workspace", "worktree", "add", "{repo}", "{head}", "--base-branch={base}", "--task-url={task_url}", "--format=json", f"--path={sys.argv[3]}"]
expected_identity = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "identity", f"{sys.argv[3]}/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider", sys.argv[4], "{handle}"]
expected_safety = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "safety", f"{sys.argv[3]}/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider", sys.argv[4], "{identity}"]
if provider.get("lookup_timeout_ms") != 10000:
    raise SystemExit("FAIL: standalone DMC lookups must retain a bounded timeout")
if provider.get("mutation_timeout_ms") != 120000:
    raise SystemExit("FAIL: DMC mutation timeout must accommodate worktree creation and bootstrap")
if commands.get("resolve_not_found_exit_codes") != [42]:
    raise SystemExit("FAIL: DMC typed-not-found classification must be exactly [42]")
if commands.get("resolve") != expected_resolve:
    raise SystemExit(f"FAIL: DMC resolve adapter mapping mismatch: {commands.get('resolve')!r}")
if commands.get("resolve_path") != expected_resolve_path:
    raise SystemExit(f"FAIL: DMC path resolve adapter mapping mismatch: {commands.get('resolve_path')!r}")
if commands.get("ensure") != expected_ensure:
    raise SystemExit(f"FAIL: DMC ensure mapping mismatch: {commands.get('ensure')!r}")
if commands.get("resolve_identity") != expected_identity:
    raise SystemExit(f"FAIL: DMC standalone identity mapping mismatch: {commands.get('resolve_identity')!r}")
if commands.get("attest_safety") != expected_safety:
    raise SystemExit(f"FAIL: DMC standalone safety mapping mismatch: {commands.get('attest_safety')!r}")
PY
}

assert_provisioning_contract() {
  python3 - "$1" "$DMC_ENSURE_LOG" <<'PY'
import json
import os
import subprocess
import sys

line = open(sys.argv[1], encoding="utf-8").read().strip()
_, payload = line.split("|", 1)
commands = json.loads(payload)["commands"]
intent = {"handle": "fixture@fix-310-dmc-cook", "repo": "fixture", "base": "main", "head": "fix/310-dmc-cook", "task_url": "https://github.com/Extra-Chill/wp-coding-agents/issues/310", "idempotency_key": "fixture@fix-310-dmc-cook:fixture:main:fix/310-dmc-cook"}

def run(name, values):
    return subprocess.run([part.format(**values) for part in commands[name]], text=True, capture_output=True, env=os.environ.copy())

first = run("resolve_identity", intent)
if first.returncode or json.loads(first.stdout).get("status") != "not_owned":
    raise SystemExit(f"FAIL: absent identity did not return a typed decline: {first!r}")
ensured = run("ensure", intent)
if ensured.returncode or not json.loads(ensured.stdout).get("success"):
    raise SystemExit(f"FAIL: DMC ensure failed: {ensured!r}")
resolved = run("resolve_identity", intent)
identity = json.loads(resolved.stdout)
if resolved.returncode or identity.get("handle") != intent["handle"]:
    raise SystemExit(f"FAIL: identity -> ensure -> identity did not converge: {resolved!r}")
safety = run("attest_safety", {**intent, "identity": identity["token"]})
if safety.returncode or json.loads(safety.stdout).get("fresh") is not True:
    raise SystemExit(f"FAIL: split safety attestation failed: {safety!r}")

PY
}

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

cat > "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" <<'PHP'
#!/usr/bin/env php
<?php
$operation = $argv[1] ?? '';
$value = $argv[3] ?? '';
if ('identity' === $operation) {
    if (!file_exists(getenv('DMC_STATE'))) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-identity/v1', 'status' => 'not_owned', 'ownership' => 'not_owned')) . "\n";
        exit(0);
    }
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-identity/v1',
        'status' => 'owned',
        'token' => 'fixture-token',
        'handle' => $value,
        'path' => getenv('DMC_STATE'),
        'branch' => 'fix/310-dmc-cook',
        'primary' => false,
        'latency_ms' => 1,
    )) . "\n";
    exit(0);
}
if ('safety' === $operation && 'fixture-token' === $value) {
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-safety/v1',
        'status' => 'attested',
        'identity_token' => $value,
        'observed_at' => '2026-08-22T00:00:00Z',
        'dirty' => false,
        'unpushed' => false,
        'fresh' => true,
        'latency_ms' => 2,
    )) . "\n";
    exit(0);
}
fwrite(STDERR, "unsupported fixture request\n");
exit(1);
PHP
chmod +x "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider"

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
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree get" ]; then
  if [ "$6" = "fixture@unrelated-exit-one" ]; then
    printf '{"success":false,"error":{"code":"workspace_unavailable"}}\n'
    exit 1
  fi
  if [ -f "$DMC_STATE" ]; then
    printf '[{"handle":"fixture@fix-310-dmc-cook","path":"%s","branch":"fix/310-dmc-cook","safety":{"dirty":false,"unpushed":false,"primary":false}}]\n' "$DMC_STATE"
    exit 0
  fi
  printf '{"success":false,"error":{"code":"worktree_not_found"}}\n'
  exit 1
fi
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree add" ]; then
  [ "$6" = "fixture" ] && [ "$7" = "fix/310-dmc-cook" ] || exit 2
  case "$*" in
    *--base-branch=main*--task-url=https://github.com/Extra-Chill/wp-coding-agents/issues/310*--format=json*) ;;
    *) exit 2 ;;
  esac
  : > "$DMC_STATE"
  printf 'ensure\n' >> "$DMC_ENSURE_LOG"
  printf '{"success":true,"handle":"fixture@fix-310-dmc-cook"}\n'
  exit 0
fi
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
DMC_STATE="$TMP/dmc-state"
DMC_ENSURE_LOG="$TMP/dmc-ensure.log"
: > "$DMC_ENSURE_LOG"
export HOMEBOY_CONFIG_LOG STUDIO_LOG DMC_STATE DMC_ENSURE_LOG

# macOS ships Bash 3.2, which has no mapfile/readarray builtin. Disable it
# when the test runs under newer Bash so this path stays portable.
enable -n mapfile 2>/dev/null || true

DRY_RUN=true
configure_homeboy_dmc_worktree_provider > "$TMP/dry-run.log"

assert_contains "homeboy config set /worktree_providers/dmc '{\"enabled\":true,\"kind\":\"command\",\"apply_enabled\":true" "$TMP/dry-run.log"
assert_contains "\"resolve_identity\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"identity\",\"$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider\",\"$DM_WORKSPACE_DIR\",\"{handle}\"]" "$TMP/dry-run.log"
assert_contains "\"attest_safety\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"safety\",\"$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider\",\"$DM_WORKSPACE_DIR\",\"{identity}\"]" "$TMP/dry-run.log"
assert_contains "\"resolve\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"resolve\",\"$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider\",\"$DM_WORKSPACE_DIR\",\"{handle}\"]" "$TMP/dry-run.log"
assert_contains "\"resolve_path\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"resolve\",\"$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider\",\"$DM_WORKSPACE_DIR\",\"{path}\"]" "$TMP/dry-run.log"
assert_contains "\"resolve_not_found_exit_codes\":[42]" "$TMP/dry-run.log"
assert_contains "\"ensure\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"add\",\"{repo}\",\"{head}\",\"--base-branch={base}\",\"--task-url={task_url}\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
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
assert_provider_mapping "$HOMEBOY_CONFIG_LOG"
assert_provider_contract "$HOMEBOY_CONFIG_LOG" "$SCRIPT_DIR" "$SITE_PATH"
assert_provisioning_contract "$HOMEBOY_CONFIG_LOG"
assert_contains "\"cleanup_apply\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"cleanup\",\"safe\",\"--format=json\",\"--path=$SITE_PATH\"]" "$HOMEBOY_CONFIG_LOG"

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
