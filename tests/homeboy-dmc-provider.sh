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

for entrypoint in setup.sh upgrade.sh; do
  discover_line=$(grep -n '^[[:space:]]*discover_dm_workspace_dir$' "$SCRIPT_DIR/$entrypoint" | tail -1 | cut -d: -f1)
  if [ "$entrypoint" = "upgrade.sh" ]; then
    configure_line=$(grep -n '^reconcile_provider_and_service_state$' "$SCRIPT_DIR/$entrypoint" | tail -1 | cut -d: -f1)
  else
    configure_line=$(grep -n '^\(  \)\?configure_homeboy_dmc_worktree_provider\(_phase\)\?$' "$SCRIPT_DIR/$entrypoint" | tail -1 | cut -d: -f1)
  fi
  if [ -z "$discover_line" ] || [ -z "$configure_line" ] || [ "$discover_line" -ge "$configure_line" ]; then
    echo "FAIL: $entrypoint must discover the authoritative DMC workspace before configuring Homeboy" >&2
    exit 1
  fi
done

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
mkdir -p "$SITE_PATH/wp-content/plugins/data-machine-code/bin" "$TMP/dmc-source/bin" "$DM_WORKSPACE_DIR"
touch "$SITE_PATH/wp-config.php"

default_transport="$(homeboy_dmc_command_json ensure)"
case "$default_transport" in
  '["wp",'*) ;;
  *)
    echo "FAIL: Studio environment metadata replaced the explicit wp transport: $default_transport"
    exit 1
    ;;
esac
WP_CMD=""
WP_CLI_TRANSPORT_JSON='["/runtime path/php","/runtime path/wp-cli.phar"]'
WP_CLI_TRANSPORT=()
argv_transport="$(homeboy_dmc_command_json ensure)"
case "$argv_transport" in
  '["/runtime path/php","/runtime path/wp-cli.phar",'*) ;;
  *)
    echo "FAIL: canonical argv transport was not serialized losslessly: $argv_transport"
    exit 1
    ;;
esac
unset WP_CLI_TRANSPORT_JSON
wp_cli_transport_set studio wp

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
  python3 - "$1" "$2" "$3" "$DM_WORKSPACE_DIR" "$DMC_PROVIDER_EXECUTABLE" "${4:-standalone}" <<'PY'
import json
import re
import sys

lines = [line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|")]
if not lines:
    raise SystemExit("FAIL: missing DMC provider config write")
_, payload = lines[-1].split("|", 1)
provider = json.loads(payload)
commands = provider["commands"]
expected_resolve = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "resolve", sys.argv[5], sys.argv[4], "{handle}"]
expected_resolve_path = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "resolve", sys.argv[5], sys.argv[4], "{path}"]
expected_resolve_task = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "resolve_task_standalone", "{task_url}", sys.argv[5], sys.argv[4]]
if sys.argv[6] == "fallback":
    expected_resolve_task = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "resolve_task", "{task_url}", "studio", "wp", "datamachine-code", "workspace", "worktree", "list", "--task-ref={task_url}", "--with-status", "--limit=200", "--envelope", "--format=json", f"--path={sys.argv[3]}"]
expected_ensure = ["studio", "wp", "datamachine-code", "workspace", "worktree", "add", "{repo}", "{head}", "--from={base}", "--task-url={task_url}", "--reuse-policy=isolated", "--purpose={purpose}", "--owner-run-ref={owner_run_ref}", "--cleanup-policy={cleanup_policy}", "--format=json", f"--path={sys.argv[3]}"]
expected_plan = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "plan_standalone", sys.argv[5], sys.argv[4], "{repo}", "{head}", "{base}", "{task_url}", "{purpose}", "{owner_run_ref}", "{cleanup_policy}"]
if sys.argv[6] == "fallback":
    expected_plan = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "plan", "studio", "wp", "datamachine-code", "workspace", "worktree", "plan", "{repo}", "{head}", "--from={base}", "--task-url={task_url}", "--reuse-policy=isolated", "--purpose={purpose}", "--owner-run-ref={owner_run_ref}", "--cleanup-policy={cleanup_policy}", "--format=json", f"--path={sys.argv[3]}"]
expected_identity = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "identity", sys.argv[5], sys.argv[4], "{handle}"]
expected_safety = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "safety", sys.argv[5], sys.argv[4], "{identity}"]
expected_converge = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "converge", sys.argv[5], sys.argv[4], "{identity}", "{base}"]
expected_attachment_preview = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "task_attachment_preview", sys.argv[5], sys.argv[4], "{handle}", "{task_url}"]
expected_attachment_apply = ["php", f"{sys.argv[2]}/scripts/homeboy-dmc-provider.php", "task_attachment_apply", "{handle}", "{task_url}", "studio", "wp", "datamachine-code", "workspace", "worktree", "attach-tracker", "{handle}", "--task-url={task_url}", "--format=json", f"--path={sys.argv[3]}"]
if provider.get("lookup_timeout_ms") != 60000:
    raise SystemExit("FAIL: standalone DMC planning must have a realistic bounded timeout")
adapter = open(commands["resolve_task"][1], encoding="utf-8").read()
adapter_budget = int(re.search(r"HOMEBOY_DMC_TASK_LOOKUP_TIMEOUT_SECONDS = (\d+)", adapter).group(1))
adapter_grace = int(re.search(r"HOMEBOY_DMC_TASK_TERMINATION_GRACE_SECONDS = (\d+)", adapter).group(1))
plan_budget = int(re.search(r"HOMEBOY_DMC_PLAN_TIMEOUT_SECONDS = (\d+)", adapter).group(1))
if adapter_budget != 8:
    raise SystemExit("FAIL: DMC task lookup must retain its inner execution deadline")
if (adapter_budget + adapter_grace) * 1000 >= provider["lookup_timeout_ms"]:
    raise SystemExit("FAIL: DMC execution and adapter cleanup must finish before Homeboy supervision")
if plan_budget != 30 or (plan_budget + adapter_grace) * 1000 >= provider["lookup_timeout_ms"]:
    raise SystemExit("FAIL: standalone planning must retain a bounded inner deadline below Homeboy supervision")
if provider.get("lookup_output_limit_bytes") != 262144:
    raise SystemExit("FAIL: DMC task lookup output must have an explicit finite Homeboy cap")
if provider.get("mutation_timeout_ms") != 120000:
    raise SystemExit("FAIL: DMC mutation timeout must accommodate worktree creation and bootstrap")
if commands.get("resolve_not_found_exit_codes") != [42]:
    raise SystemExit("FAIL: DMC typed-not-found classification must be exactly [42]")
mapping = provider.get("list_result_mapping")
if mapping != {"items": "$", "handle": "$.handle", "path": "$.path", "branch": "$.branch", "task_url": "$.task_url", "dirty": "$.safety.dirty", "unpushed": "$.safety.unpushed", "primary": "$.safety.primary"}:
    raise SystemExit(f"FAIL: DMC resolve mapping must explicitly project tracker ownership: {mapping!r}")
if commands.get("resolve") != expected_resolve:
    raise SystemExit(f"FAIL: DMC resolve adapter mapping mismatch: {commands.get('resolve')!r}")
if commands.get("resolve_path") != expected_resolve_path:
    raise SystemExit(f"FAIL: DMC path resolve adapter mapping mismatch: {commands.get('resolve_path')!r}")
if commands.get("resolve_task") != expected_resolve_task:
    raise SystemExit(f"FAIL: DMC task resolve adapter mapping mismatch: {commands.get('resolve_task')!r}")
if commands.get("resolve_task_not_found_exit_codes") != [42]:
    raise SystemExit("FAIL: DMC task lookup must declare Homeboy's recognized task-specific absence exit")
if commands.get("ensure") != expected_ensure:
    raise SystemExit(f"FAIL: DMC ensure mapping mismatch: {commands.get('ensure')!r}")
if commands.get("plan") != expected_plan:
    raise SystemExit(f"FAIL: DMC plan mapping mismatch: {commands.get('plan')!r}")
if commands.get("resolve_identity") != expected_identity:
    raise SystemExit(f"FAIL: DMC standalone identity mapping mismatch: {commands.get('resolve_identity')!r}")
if commands.get("attest_safety") != expected_safety:
    raise SystemExit(f"FAIL: DMC standalone safety mapping mismatch: {commands.get('attest_safety')!r}")
if commands.get("converge") != expected_converge:
    raise SystemExit(f"FAIL: DMC convergence mapping must bind the opaque identity and pinned base: {commands.get('converge')!r}")
if commands.get("task_attachment_preview") != expected_attachment_preview:
    raise SystemExit(f"FAIL: DMC task-attachment preview mapping mismatch: {commands.get('task_attachment_preview')!r}")
if commands.get("task_attachment_apply") != expected_attachment_apply:
    raise SystemExit(f"FAIL: DMC task-attachment apply mapping mismatch: {commands.get('task_attachment_apply')!r}")
if "finalize" in commands:
    raise SystemExit("FAIL: lifecycle finalization must use Homeboy's generic lifecycle settings")
if "list" in commands:
    raise SystemExit("FAIL: DMC provider must not advertise unsupported generic list capability")
PY
}

assert_convergence_contract() {
  python3 - "$1" "$DMC_PROVIDER_LOG" <<'PY'
import json
import os
import subprocess
import sys

line = next(line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|"))
_, payload = line.split("|", 1)
command = json.loads(payload)["commands"]["converge"]
identity = "fixture-token"
base = "0123456789012345678901234567890123456789"

def run(mode):
    env = os.environ.copy()
    env["DMC_CONVERGENCE_MODE"] = mode
    return subprocess.run([part.replace("{identity}", identity).replace("{base}", base) for part in command], text=True, capture_output=True, env=env)

success = run("success")
expected = {"schema": "homeboy/worktree-provider-convergence/v1", "identity_token": identity, "base_sha": base}
if success.returncode or json.loads(success.stdout) != expected:
    raise SystemExit(f"FAIL: DMC convergence success did not preserve exact Homeboy evidence: {success!r}")

refused = run("refused")
if refused.returncode == 0 or refused.stdout:
    raise SystemExit(f"FAIL: DMC refused convergence response must fail closed: {refused!r}")
if "unsupported envelope" in refused.stderr:
    raise SystemExit(f"FAIL: typed convergence refusal was misreported as an unsupported envelope: {refused!r}")
try:
    refusal = json.loads(refused.stderr)
except ValueError:
    raise SystemExit(f"FAIL: DMC convergence refusal was not a machine-readable typed envelope: {refused!r}")
if refusal != {"schema": "homeboy/worktree-provider-convergence-refusal/v1", "identity_token": identity, "base_sha": base, "code": "destination_diverged", "message": "DMC refused worktree convergence: destination_diverged"}:
    raise SystemExit(f"FAIL: DMC convergence refusal did not preserve the provider's typed refusal code: {refused!r}")

for mode in ("mismatched", "stale", "refused_mismatched", "refused_stale", "refused_codeless", "unknown_schema"):
    result = run(mode)
    if result.returncode == 0 or result.stdout:
        raise SystemExit(f"FAIL: DMC {mode} convergence response must fail closed: {result!r}")
    if "unsupported envelope" not in result.stderr:
        raise SystemExit(f"FAIL: DMC {mode} convergence response must keep the unsupported-envelope contract violation diagnostic: {result!r}")

log = open(sys.argv[2], encoding="utf-8").read()
if f"converge|{identity}|{base}" not in log:
    raise SystemExit("FAIL: DMC converge did not receive the opaque identity and pinned base")
PY
}

assert_provisioning_contract() {
  python3 - "$1" "$DMC_ENSURE_LOG" "$DMC_PLAN_PATH" <<'PY'
import json
import os
import subprocess
import sys

lines = [line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|")]
if not lines:
    raise SystemExit("FAIL: missing DMC provider config write")
_, payload = lines[-1].split("|", 1)
commands = json.loads(payload)["commands"]
# Homeboy normalizes the configured php-transformer component to its canonical
# blocks-engine repository before the provider sees the worktree intent.
intent = {"handle": "blocks-engine@fix-406-dmc-provider-plan", "repo": "blocks-engine", "base": "origin/main", "head": "fix/406-dmc-provider-plan", "task_url": "https://github.com/Extra-Chill/wp-coding-agents/issues/406", "idempotency_key": "blocks-engine@fix-406-dmc-provider-plan:blocks-engine:origin/main:fix/406-dmc-provider-plan", "purpose": "agent-task-cook", "owner_run_ref": "homeboy://agent-task/run/cook-406", "cleanup_policy": "remove_on_success"}

def run(name, values):
    return subprocess.run([part.format(**values) for part in commands[name]], text=True, capture_output=True, env=os.environ.copy())

first = run("resolve_identity", intent)
if first.returncode or json.loads(first.stdout).get("status") != "not_owned":
    raise SystemExit(f"FAIL: absent identity did not return a typed decline: {first!r}")
planned = run("plan", intent)
if planned.returncode or json.loads(planned.stdout) != [{"handle": intent["handle"], "path": sys.argv[3], "branch": intent["head"], "safety": {"dirty": False, "unpushed": False, "primary": False}}]:
    raise SystemExit(f"FAIL: DMC plan did not project the canonical destination: {planned!r}")
if os.path.exists(sys.argv[3]):
    raise SystemExit("FAIL: DMC plan created its destination")

trackerless = {**intent, "task_url": "", "purpose": "release_staging", "owner_run_ref": "release/fixture-owner"}
env = os.environ.copy()
env["DMC_PLAN_TRACKERLESS"] = "1"
planned = subprocess.run([part.format(**trackerless) for part in commands["plan"]], text=True, capture_output=True, env=env)
if planned.returncode or not json.loads(planned.stdout):
    raise SystemExit(f"FAIL: trackerless release staging was not plannable: {planned!r}")
missing_owner = subprocess.run([part.format(**{**trackerless, "owner_run_ref": ""}) for part in commands["plan"]], text=True, capture_output=True, env=env)
if missing_owner.returncode != 2 or "Usage: homeboy-dmc-provider.php plan_standalone" not in missing_owner.stderr:
    raise SystemExit(f"FAIL: trackerless planning accepted a missing lifecycle owner: {missing_owner!r}")

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

for disposition in ("exact_reuse", "capacity_blocked", "owner_conflict"):
    env = os.environ.copy()
    env["DMC_PLAN_DISPOSITION"] = disposition
    result = subprocess.run([part.format(**intent) for part in commands["plan"]], text=True, capture_output=True, env=env)
    if disposition == "exact_reuse":
        if result.returncode or not json.loads(result.stdout):
            raise SystemExit(f"FAIL: exact compatible reuse was not plannable: {result!r}")
    elif result.returncode == 0 or f"{disposition}" not in result.stderr:
        raise SystemExit(f"FAIL: {disposition} was not an exact plan refusal: {result!r}")

for disposition in ("unsafe", "ownership conflict"):
    env = os.environ.copy()
    env["DMC_PLAN_TEXT_DISPOSITION"] = disposition
    result = subprocess.run([part.format(**intent) for part in commands["plan"]], text=True, capture_output=True, env=env)
    normalized = "owner_conflict" if disposition == "ownership conflict" else disposition
    if result.returncode == 0 or f"DMC worktree plan disposition: {normalized}" not in result.stderr:
        raise SystemExit(f"FAIL: textual {disposition} evidence was collapsed: {result!r}")

PY
}

assert_finalization_contract() {
  python3 - "$1" "$STUDIO_LOG" <<'PY'
import json
import subprocess
import sys

lines = [line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/settings/worktree_provider_lifecycle/dmc/finalize|")]
if not lines:
    raise SystemExit("FAIL: missing Homeboy DMC lifecycle finalizer config write")
_, payload = lines[-1].split("|", 1)
command = json.loads(payload)
handle = "wp-codebox@release-wp-codebox-6b69fc607f7f"
if any(argument.startswith("--state=") for argument in command):
    raise SystemExit("FAIL: Homeboy lifecycle states must not leak into DMC's state machine")

def run(owner_outcome):
    values = {
        "handle": handle,
        "owner_outcome": owner_outcome,
    }
    return subprocess.run([part.format(**values) for part in command], text=True, capture_output=True)

open(sys.argv[2], "w").close()
for owner_outcome in ("success", "failure"):
    result = run(owner_outcome)
    if result.returncode or not json.loads(result.stdout).get("success"):
        raise SystemExit(f"FAIL: DMC {owner_outcome} finalization failed: {result!r}")

log = open(sys.argv[2], encoding="utf-8").read()
for owner_outcome in ("success", "failure"):
    expected = f"workspace worktree finalize {handle} --owner-terminal-outcome={owner_outcome} --format=json"
    if expected not in log:
        raise SystemExit(f"FAIL: missing exact DMC finalization argv {expected!r}: {log!r}")
PY
}

assert_resolution_contract() {
  python3 - "$1" "$DMC_STATE" <<'PY'
import json
import os
import subprocess
import sys

line = next(line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|"))
_, payload = line.split("|", 1)
commands = json.loads(payload)["commands"]
intent = {"handle": "fixture@fix-310-dmc-cook", "path": sys.argv[2], "repo": "fixture"}

def run(mode="", command_name="resolve"):
    env = os.environ.copy()
    env["DMC_INVENTORY_MODE"] = mode
    return subprocess.run([part.replace("{handle}", intent["handle"]).replace("{path}", intent["path"]) for part in commands[command_name]], text=True, capture_output=True, env=env)

resolved = run()
expected = [{"handle": intent["handle"], "path": intent["path"], "branch": "fix/310-dmc-cook", "task_url": "https://github.com/Extra-Chill/wp-coding-agents/issues/419", "safety": {"dirty": False, "unpushed": False, "primary": False}}]
if resolved.returncode or json.loads(resolved.stdout) != expected:
    raise SystemExit(f"FAIL: resolve did not project signed tracker identity: {resolved!r}")
resolved_path = run(command_name="resolve_path")
if resolved_path.returncode or json.loads(resolved_path.stdout) != expected:
    raise SystemExit(f"FAIL: resolve_path did not project signed tracker identity: {resolved_path!r}")
canonical = run("canonical_task")
if canonical.returncode or json.loads(canonical.stdout) != expected:
    raise SystemExit(f"FAIL: exact resolution did not canonicalize persisted task identity: {canonical!r}")
missing = run("missing_task")
missing_expected = [{**expected[0], "task_url": None}]
if missing.returncode or json.loads(missing.stdout) != missing_expected:
    raise SystemExit(f"FAIL: lifecycle-owned handle resolution did not project a null tracker: {missing!r}")
missing_path = run("missing_task", "resolve_path")
if missing_path.returncode or json.loads(missing_path.stdout) != missing_expected:
    raise SystemExit(f"FAIL: exact path resolution did not preserve an untracked worktree for negotiated attachment: {missing_path!r}")
malformed = run("malformed")
if malformed.returncode == 0 or "incomplete exact identity" not in malformed.stderr:
    raise SystemExit(f"FAIL: malformed standalone identity must fail closed: {malformed!r}")
PY
}

assert_task_resolution_contract() {
  python3 - "$1" <<'PY'
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

line = next(line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|"))
_, payload = line.split("|", 1)
command = json.loads(payload)["commands"]["resolve_task"]
task_url = "https://github.com/Extra-Chill/wp-coding-agents/issues/425"

def run(mode, requested_task_url=task_url, watchdog=None):
    env = os.environ.copy()
    env["DMC_TASK_LOOKUP_MODE"] = mode
    args = [part.replace("{task_url}", requested_task_url) for part in command]
    if watchdog is None:
        return subprocess.run(args, text=True, capture_output=True, env=env)
    with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
        process = subprocess.Popen(args, text=True, stdout=stdout, stderr=stderr, env=env)
        try:
            returncode = process.wait(timeout=watchdog)
        except subprocess.TimeoutExpired:
            try:
                child_pid = int(open(os.environ["DMC_CHILD_PID"], encoding="utf-8").read())
                os.killpg(child_pid, signal.SIGKILL)
            except (FileNotFoundError, ProcessLookupError, ValueError):
                pass
            process.kill()
            process.wait(timeout=2)
            raise SystemExit(f"FAIL: {mode} lookup exceeded independent {watchdog}s fixture watchdog")
        stdout.seek(0)
        stderr.seek(0)
        return subprocess.CompletedProcess(args, returncode, stdout.read(), stderr.read())

zero = run("zero")
if zero.returncode != 42 or json.loads(zero.stdout).get("error", {}).get("code") != "worktree_not_found":
    raise SystemExit(f"FAIL: zero task candidates must return the task-specific typed absence: {zero!r}")
one = run("one")
expected = [{"handle": "fixture@task-425", "path": os.environ["DMC_STATE"], "branch": "fix/425-resolve-task", "task_url": "https://github.com/Extra-Chill/wp-coding-agents/issues/425", "safety": {"dirty": False, "unpushed": False, "primary": False}}]
if one.returncode or json.loads(one.stdout) != expected:
    raise SystemExit(f"FAIL: one task candidate did not retain its full identity: {one!r}")
diagnostic_prefix = run("diagnostic_prefix")
if diagnostic_prefix.returncode or json.loads(diagnostic_prefix.stdout) != expected:
    raise SystemExit(f"FAIL: recognized PHP diagnostics must not contaminate typed task lookup JSON: {diagnostic_prefix!r}")
arbitrary_prefix = run("arbitrary_prefix")
if arbitrary_prefix.returncode == 0 or arbitrary_prefix.stdout or "invalid JSON" not in arbitrary_prefix.stderr:
    raise SystemExit(f"FAIL: arbitrary task lookup prefixes must fail closed: {arbitrary_prefix!r}")
ambiguous = run("ambiguous")
if ambiguous.returncode or [item["handle"] for item in json.loads(ambiguous.stdout)] != ["fixture@task-425", "fixture@task-425-other"]:
    raise SystemExit(f"FAIL: ambiguous task candidates must retain DMC's complete bounded set: {ambiguous!r}")
canonical = run("canonical", " HTTPS://GITHUB.COM/Extra-Chill/WP-Coding-Agents/issues/425/?query=value#fragment ")
canonical_expected = [{**expected[0], "task_url": "https://github.com/Extra-Chill/WP-Coding-Agents/issues/425"}]
if canonical.returncode or json.loads(canonical.stdout) != canonical_expected:
    raise SystemExit(f"FAIL: task lookup did not canonicalize requested and stored task URLs: {canonical!r}")
https_default_port = run("one", " HTTPS://GITHUB.COM:443/Extra-Chill/wp-coding-agents/issues/425/?source=fixture#result ")
if https_default_port.returncode or json.loads(https_default_port.stdout) != expected:
    raise SystemExit(f"FAIL: HTTPS default port was not removed without changing path case: {https_default_port!r}")
https_zero_padded_port = run("one", " HTTPS://GITHUB.COM:0443/Extra-Chill/wp-coding-agents/issues/425/?source=fixture#result ")
if https_zero_padded_port.returncode or json.loads(https_zero_padded_port.stdout) != expected:
    raise SystemExit(f"FAIL: zero-padded HTTPS default port did not round-trip through the adapter: {https_zero_padded_port!r}")
http_default_port = run("default_http", " HTTP://GITHUB.COM:80/Extra-Chill/wp-coding-agents/issues/425/?source=fixture#result ")
http_expected = [{**expected[0], "task_url": "http://github.com/Extra-Chill/wp-coding-agents/issues/425"}]
if http_default_port.returncode or json.loads(http_default_port.stdout) != http_expected:
    raise SystemExit(f"FAIL: HTTP default port was not removed without changing path case: {http_default_port!r}")
http_zero_padded_port = run("default_http", " HTTP://GITHUB.COM:080/Extra-Chill/wp-coding-agents/issues/425/?source=fixture#result ")
if http_zero_padded_port.returncode or json.loads(http_zero_padded_port.stdout) != http_expected:
    raise SystemExit(f"FAIL: zero-padded HTTP default port did not round-trip through the adapter: {http_zero_padded_port!r}")
started = time.monotonic()
large_inventory = run("large_inventory")
elapsed = time.monotonic() - started
if large_inventory.returncode or json.loads(large_inventory.stdout) != expected or elapsed >= 12:
    raise SystemExit(f"FAIL: exact-task projection did not complete within Homeboy's declared supervision budget: {large_inventory!r}, elapsed={elapsed}")
largest_success = run("largest_success")
largest_rows = json.loads(largest_success.stdout) if largest_success.returncode == 0 else []
largest_size = len(largest_success.stdout.encode("utf-8"))
if len(largest_rows) != 200 or largest_rows[0]["handle"] != "fixture@task-425-001" or largest_rows[-1]["handle"] != "fixture@task-425-200" or not 100000 < largest_size < 131072 or largest_size >= 262144:
    raise SystemExit(f"FAIL: largest successful task projection did not stay below both adapter and Homeboy caps: {largest_success!r}")
for mode in ("mismatched_task", "incomplete_safety", "incomplete_page", "overflow", "over_budget", "aggregate_over_budget", "escaping_over_budget", "oversized_stdout", "oversized_stderr"):
    result = run(mode)
    expected_error = "bounded stdout capture" if mode == "oversized_stdout" else "bounded stderr capture" if mode == "oversized_stderr" else "complete candidate bound" if mode == "overflow" else "bounded output" if mode in ("aggregate_over_budget", "escaping_over_budget") else "bounded limit" if mode == "over_budget" else "complete bounded page" if mode == "incomplete_page" else "incomplete or mismatched task candidate"
    if result.returncode == 0 or expected_error not in result.stderr:
        raise SystemExit(f"FAIL: {mode} task candidate must fail closed: {result!r}")

def assert_descendant_stopped(mode, expected_error, timeout):
    markers = (os.environ["DMC_CHILD_PID"], os.environ["DMC_DESCENDANT_PID"])
    for marker in markers:
        try:
            os.unlink(marker)
        except FileNotFoundError:
            pass
    started = time.monotonic()
    result = run(mode, watchdog=20)
    elapsed = time.monotonic() - started
    if result.returncode == 0 or expected_error not in result.stderr or elapsed >= timeout:
        raise SystemExit(f"FAIL: {mode} lookup did not fail closed within its bound: {result!r}, elapsed={elapsed}")
    for marker in markers:
        try:
            pid = int(open(marker, encoding="utf-8").read())
        except (FileNotFoundError, ValueError) as error:
            raise SystemExit(f"FAIL: {mode} fixture did not record {marker}: {error}")
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"FAIL: {mode} lookup left process {pid} alive")

assert_descendant_stopped("descendant_both", "bounded ", 5)
assert_descendant_stopped("descendant_silent", "execution exceeded the adapter budget", 11)
PY
}

assert_standalone_task_resolution_contract() {
  python3 - "$1" "$STUDIO_LOG" <<'PY'
import json
import os
import subprocess
import sys

lines = [line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|")]
_, payload = lines[-1].split("|", 1)
command = json.loads(payload)["commands"]["resolve_task"]
task = "https://github.com/Extra-Chill/wp-coding-agents/issues/425"

def run(mode):
    env = os.environ.copy()
    env["DMC_TASK_LOOKUP_MODE"] = mode
    return subprocess.run([part.replace("{task_url}", task) for part in command], text=True, capture_output=True, env=env)

missing = run("zero")
if missing.returncode != 42 or json.loads(missing.stdout).get("error", {}).get("code") != "worktree_not_found":
    raise SystemExit(f"FAIL: standalone task absence was not typed: {missing!r}")

resolved = run("one")
rows = json.loads(resolved.stdout) if resolved.returncode == 0 else []
if len(rows) != 1 or rows[0].get("handle") != "fixture@task-425" or rows[0].get("task_url") != task:
    raise SystemExit(f"FAIL: standalone task resolution was not preserved: {resolved!r}")

for mode in ("malformed", "mismatched_task", "incomplete_safety", "failure"):
    failed = run(mode)
    if failed.returncode == 0 or failed.stdout:
        raise SystemExit(f"FAIL: standalone {mode} response did not fail closed: {failed!r}")

if "wp datamachine-code workspace worktree list" in open(sys.argv[2], encoding="utf-8").read():
    raise SystemExit("FAIL: standalone task resolution invoked studio wp")
PY
}

assert_task_attachment_contract() {
  python3 - "$1" <<'PY'
import json
import os
import subprocess
import sys

line = next(line for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line.startswith("/worktree_providers/dmc|"))
_, payload = line.split("|", 1)
commands = json.loads(payload)["commands"]
handle = "static-site-importer@refactor-1306-runtime-entity-form-materialization"
task_url = "https://github.com/Automattic/static-site-importer/issues/1306"
values = {"handle": handle, "task_url": task_url}

path_resolution = subprocess.run(
    [part.replace("{path}", os.environ["DMC_ATTACHMENT_PATH"]) for part in commands["resolve_path"]],
    text=True,
    capture_output=True,
    env=os.environ.copy(),
)
path_rows = json.loads(path_resolution.stdout) if path_resolution.returncode == 0 else []
if len(path_rows) != 1 or path_rows[0].get("handle") != handle or path_rows[0].get("path") != os.environ["DMC_ATTACHMENT_PATH"] or path_rows[0].get("task_url") is not None:
    raise SystemExit(f"FAIL: --cwd path did not resolve the exact untracked DMC handle before attachment: {path_resolution!r}")

def run(name, env=None):
    command = [part.format(**values) for part in commands[name]]
    return subprocess.run(command, text=True, capture_output=True, env=env or os.environ.copy())

preview = run("task_attachment_preview")
expected = {
    "schema": "homeboy/worktree-provider-task-attachment/v1",
    "provider_id": "dmc",
    "handle": handle,
    "task_url": task_url,
    "path": os.environ["DMC_ATTACHMENT_PATH"],
    "branch": "refactor-1306-runtime-entity-form-materialization",
    "primary": False,
    "status": "eligible",
}
if preview.returncode or json.loads(preview.stdout) != expected:
    raise SystemExit(f"FAIL: read-only attachment preview did not return exact eligible evidence: {preview!r}")
if os.path.exists(os.environ["DMC_ATTACHMENT_STATE"]):
    raise SystemExit("FAIL: task-attachment preview mutated tracker metadata")

applied = run("task_attachment_apply")
if applied.returncode or json.loads(applied.stdout) != {**expected, "status": "attached"}:
    raise SystemExit(f"FAIL: task-attachment apply did not adapt DMC attached evidence: {applied!r}")
if not os.path.exists(os.environ["DMC_ATTACHMENT_STATE"]):
    raise SystemExit("FAIL: task-attachment apply did not invoke authorized DMC attachment")

resolved = subprocess.run(
    [part.replace("{handle}", handle) for part in commands["resolve"]],
    text=True,
    capture_output=True,
    env=os.environ.copy(),
)
resolved_expected = [{
    "handle": handle,
    "path": os.environ["DMC_ATTACHMENT_PATH"],
    "branch": "refactor-1306-runtime-entity-form-materialization",
    "task_url": task_url,
    "safety": {"dirty": False, "unpushed": False, "primary": False},
}]
if resolved.returncode or json.loads(resolved.stdout) != resolved_expected:
    raise SystemExit(f"FAIL: attached #1306 worktree did not resolve normally: {resolved!r}")

replay_preview = run("task_attachment_preview")
if replay_preview.returncode or json.loads(replay_preview.stdout) != {**expected, "status": "already_attached"}:
    raise SystemExit(f"FAIL: attachment replay preview was not idempotent: {replay_preview!r}")
replay_apply = run("task_attachment_apply")
if replay_apply.returncode or json.loads(replay_apply.stdout) != {**expected, "status": "already_attached"}:
    raise SystemExit(f"FAIL: DMC already-attached apply result was not preserved: {replay_apply!r}")

for mode in ("conflict", "dirty", "foreign", "ambiguous", "inactive"):
    env = os.environ.copy()
    env["DMC_ATTACHMENT_ERROR"] = mode
    failure = run("task_attachment_apply", env)
    if failure.returncode != 17 or failure.stdout or failure.stderr != f"dmc-{mode}\n":
        raise SystemExit(f"FAIL: bounded DMC {mode} stderr/exit failure was not preserved: {failure!r}")
PY
}

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

cat > "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" <<'PHP'
#!/usr/bin/env php
<?php
$operation = $argv[1] ?? '';
$value = $argv[3] ?? '';
$base = $argv[4] ?? '';
file_put_contents(getenv('DMC_PROVIDER_LOG'), $operation . "|" . $value . ('' === $base ? '' : "|" . $base) . "\n", FILE_APPEND);
if ('identity' === $operation) {
    $attachment_handle = 'static-site-importer@refactor-1306-runtime-entity-form-materialization';
    if ($attachment_handle === $value) {
        $task_url = file_exists(getenv('DMC_ATTACHMENT_STATE')) ? 'https://github.com/Automattic/static-site-importer/issues/1306' : null;
        echo json_encode(array(
            'schema' => 'datamachine-code/worktree-identity/v1',
            'status' => 'owned',
            'token' => 'attachment-token',
            'handle' => $value,
            'path' => getenv('DMC_ATTACHMENT_PATH'),
            'branch' => 'refactor-1306-runtime-entity-form-materialization',
            'primary' => false,
            'task_url' => $task_url,
            'latency_ms' => 1,
        )) . "\n";
        exit(0);
    }
    if (!file_exists(getenv('DMC_STATE'))) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-identity/v1', 'status' => 'not_owned', 'ownership' => 'not_owned')) . "\n";
        exit(0);
    }
    $mode = getenv('DMC_INVENTORY_MODE');
    $task_url = 'missing_task' === $mode ? null : ('canonical_task' === $mode ? ' HTTPS://GITHUB.COM/Extra-Chill/wp-coding-agents/issues/419/?query=value#fragment ' : 'https://github.com/Extra-Chill/wp-coding-agents/issues/419');
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-identity/v1',
        'status' => 'owned',
        'token' => 'fixture-token',
        'handle' => $value,
        'path' => getenv('DMC_STATE'),
        'branch' => 'malformed' === $mode ? '' : 'fix/310-dmc-cook',
        'primary' => false,
        'task_url' => $task_url,
        'latency_ms' => 1,
    )) . "\n";
    exit(0);
}
if ('capabilities' === $operation) {
    if ('legacy' === getenv('DMC_CAPABILITIES_MODE')) {
        fwrite(STDERR, "unsupported fixture request\n");
        exit(2);
    }
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-provider-capabilities/v1',
        'operations' => 'task_legacy' === getenv('DMC_CAPABILITIES_MODE') ? array('identity', 'safety', 'converge', 'capabilities') : array('identity', 'task', 'safety', 'converge', 'plan', 'capabilities'),
        'tracker_fields' => array('task_url', 'task_ref'),
        'attachment_operation' => 'datamachine-code/workspace-worktree-attach-tracker',
        'attachment_standalone' => false,
        'task_resolution_schema' => 'datamachine-code/worktree-task-resolution/v1',
        'task_resolution_limit' => 200,
        'plan_schema' => 'datamachine-code/worktree-plan/v1',
        'plan_mutating' => false,
    )) . "\n";
    exit(0);
}
if ('plan' === $operation) {
    $intent = json_decode($argv[3] ?? '', true);
    $expected = array(
        'repo' => 'blocks-engine',
        'branch' => 'fix/406-dmc-provider-plan',
        'from' => 'origin/main',
        'task_url' => getenv('DMC_PLAN_TRACKERLESS') ? null : 'https://github.com/Extra-Chill/wp-coding-agents/issues/406',
        'reuse_policy' => 'isolated',
        'purpose' => getenv('DMC_PLAN_TRACKERLESS') ? 'release_staging' : 'agent-task-cook',
        'owner_run_ref' => getenv('DMC_PLAN_TRACKERLESS') ? 'release/fixture-owner' : 'homeboy://agent-task/run/cook-406',
        'cleanup_policy' => 'remove_on_success',
    );
    if ($intent !== $expected) {
        fwrite(STDERR, "standalone plan intent mismatch\n");
        exit(2);
    }
    file_put_contents(getenv('DMC_ENSURE_LOG'), "plan\n", FILE_APPEND);
    if ('' !== (string) getenv('DMC_PLAN_TEXT_DISPOSITION')) {
        fwrite(STDOUT, 'Disposition: ' . getenv('DMC_PLAN_TEXT_DISPOSITION') . "\n");
        exit(9);
    }
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-plan/v1',
        'version' => 1,
        'digest' => 'fixture-plan-digest',
        'handle' => 'blocks-engine@fix-406-dmc-provider-plan',
        'path' => getenv('DMC_PLAN_PATH'),
        'branch' => 'fix/406-dmc-provider-plan',
        'disposition' => getenv('DMC_PLAN_DISPOSITION') ?: 'create',
    )) . "\n";
    exit(0);
}
if ('task' === $operation) {
    $task_url = $argv[3] ?? '';
    $mode = getenv('DMC_TASK_LOOKUP_MODE') ?: 'zero';
    if ('failure' === $mode) {
        fwrite(STDERR, "standalone task failure\n");
        exit(17);
    }
    if ('malformed' === $mode) {
        echo "not-json\n";
        exit(0);
    }
    $candidate_task = 'mismatched_task' === $mode ? 'https://github.com/Extra-Chill/wp-coding-agents/issues/other' : $task_url;
    $safety = 'incomplete_safety' === $mode ? array('dirty' => false, 'primary' => false) : array('dirty' => false, 'unpushed' => false, 'primary' => false);
    $candidates = 'zero' === $mode ? array() : array(array(
        'handle' => 'fixture@task-425',
        'path' => getenv('DMC_STATE'),
        'branch' => 'fix/425-resolve-task',
        'task_url' => $candidate_task,
        'safety' => $safety,
    ));
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-task-resolution/v1',
        'status' => 'complete',
        'task_url' => $task_url,
        'total' => count($candidates),
        'candidates' => $candidates,
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
if ('safety' === $operation && 'attachment-token' === $value) {
    echo json_encode(array(
        'schema' => 'datamachine-code/worktree-safety/v1',
        'status' => 'attested',
        'identity_token' => $value,
        'observed_at' => '2026-08-25T00:00:00Z',
        'dirty' => false,
        'unpushed' => false,
        'fresh' => true,
        'latency_ms' => 2,
    )) . "\n";
    exit(0);
}
if ('converge' === $operation && 'fixture-token' === $value) {
    $mode = getenv('DMC_CONVERGENCE_MODE');
    if ('success' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'converged', 'identity_token' => $value, 'base_sha' => $base)) . "\n";
        exit(0);
    }
    if ('mismatched' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'converged', 'identity_token' => 'other-token', 'base_sha' => $base)) . "\n";
        exit(0);
    }
    if ('stale' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'stale', 'identity_token' => $value, 'base_sha' => $base)) . "\n";
        exit(0);
    }
    if ('refused' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'refused', 'code' => 'destination_diverged', 'identity_token' => $value, 'base_sha' => $base, 'before_head' => '1111111111111111111111111111111111111111', 'after_head' => '2222222222222222222222222222222222222222', 'changed' => false)) . "\n";
        exit(0);
    }
    if ('refused_mismatched' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'refused', 'code' => 'destination_diverged', 'identity_token' => 'other-token', 'base_sha' => $base)) . "\n";
        exit(0);
    }
    if ('refused_stale' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'refused', 'code' => 'destination_diverged', 'identity_token' => $value, 'base_sha' => '0000000000000000000000000000000000000000')) . "\n";
        exit(0);
    }
    if ('refused_codeless' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v1', 'status' => 'refused', 'identity_token' => $value, 'base_sha' => $base)) . "\n";
        exit(0);
    }
    if ('unknown_schema' === $mode) {
        echo json_encode(array('schema' => 'datamachine-code/worktree-convergence/v2', 'status' => 'refused', 'code' => 'destination_diverged', 'identity_token' => $value, 'base_sha' => $base)) . "\n";
        exit(0);
    }
}
fwrite(STDERR, "unsupported fixture request\n");
exit(1);
PHP
chmod +x "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider"
cp "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" "$TMP/dmc-source/bin/dmc-worktree-provider"
chmod +x "$TMP/dmc-source/bin/dmc-worktree-provider"

cat > "$FAKE_BIN/homeboy" <<'SH'
#!/bin/sh
if [ "$1 $2" = "config set" ]; then
  if [ "$3" = "/worktree_providers/wpca-task-attachment-probe" ]; then
    [ "${HOMEBOY_ATTACHMENT_COMMANDS:-true}" = true ] && : > "$HOMEBOY_DATA_DIR/task-attachment-supported"
    exit 0
  fi
  printf '%s|%s\n' "$3" "$4" >> "$HOMEBOY_CONFIG_LOG"
  exit 0
fi
if [ "$1 $2" = "config show" ]; then
  if [ "$3" = "/settings/worktree_provider_lifecycle/dmc/finalize" ]; then
    grep -qF -- "$3|" "$HOMEBOY_CONFIG_LOG"
    exit $?
  fi
  [ "${HOMEBOY_ATTACHMENT_COMMANDS:-true}" = true ] && [ -f "$HOMEBOY_DATA_DIR/task-attachment-supported" ] && exit 0
  exit 2
fi
exit 2
SH
chmod +x "$FAKE_BIN/homeboy"

cat > "$FAKE_BIN/studio" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUDIO_LOG"
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree list" ]; then
  case "$*" in
    *--task-ref=https://github.com/Extra-Chill/wp-coding-agents/issues/425*--with-status*--limit=200*--envelope*--format=json*|*--task-ref=https://github.com/Extra-Chill/WP-Coding-Agents/issues/425*--with-status*--limit=200*--envelope*--format=json*|*--task-ref=http://github.com/Extra-Chill/wp-coding-agents/issues/425*--with-status*--limit=200*--envelope*--format=json*) ;;
    *) exit 2 ;;
  esac
  printf '%s\n' "$$" > "$DMC_CHILD_PID"
  case "${DMC_TASK_LOOKUP_MODE:-zero}" in
    zero)
      printf '{"success":true,"total":0,"returned":0,"next_cursor":null,"worktrees":[]}\n'
      ;;
    one|diagnostic_prefix|arbitrary_prefix|ambiguous|canonical|mismatched_task|incomplete_safety|default_http|large_inventory)
      task='https://github.com/Extra-Chill/wp-coding-agents/issues/425'
      [ "${DMC_TASK_LOOKUP_MODE:-}" = mismatched_task ] && task='https://github.com/Extra-Chill/wp-coding-agents/issues/other'
      [ "${DMC_TASK_LOOKUP_MODE:-}" = canonical ] && task='HTTPS://GITHUB.COM/Extra-Chill/WP-Coding-Agents/issues/425/?query=value#fragment'
      [ "${DMC_TASK_LOOKUP_MODE:-}" = default_http ] && task='http://github.com/Extra-Chill/wp-coding-agents/issues/425'
      safety='{"dirty":false,"unpushed":false,"primary":false}'
      [ "${DMC_TASK_LOOKUP_MODE:-}" = incomplete_safety ] && safety='{"dirty":false,"primary":false}'
      if [ "${DMC_TASK_LOOKUP_MODE:-}" = large_inventory ]; then
        i=1
        while [ "$i" -le 5000 ]; do i=$((i + 1)); done
      fi
      [ "${DMC_TASK_LOOKUP_MODE:-}" = diagnostic_prefix ] && printf '\nDeprecated: Case statements followed by a semicolon are deprecated.\n'
      [ "${DMC_TASK_LOOKUP_MODE:-}" = arbitrary_prefix ] && printf 'unexpected output\n'
      printf '{"success":true,"total":%s,"returned":%s,"next_cursor":null,"worktrees":[{"handle":"fixture@task-425","path":"%s","branch":"fix/425-resolve-task","task_full":{"task_url":"%s"},"safety":%s}' "$( [ "${DMC_TASK_LOOKUP_MODE:-}" = ambiguous ] && printf 2 || printf 1 )" "$( [ "${DMC_TASK_LOOKUP_MODE:-}" = ambiguous ] && printf 2 || printf 1 )" "$DMC_STATE" "$task" "$safety"
      if [ "${DMC_TASK_LOOKUP_MODE:-}" = ambiguous ]; then
        printf ',{"handle":"fixture@task-425-other","path":"%s-other","branch":"fix/425-resolve-task","task_full":{"task_url":"%s"},"safety":{"dirty":false,"unpushed":false,"primary":false}}' "$DMC_STATE" "$task"
      fi
      printf ']}\n'
      ;;
    largest_success|aggregate_over_budget|escaping_over_budget)
      python3 -c 'import json, sys; mode, path = sys.argv[1:]; task = "https://github.com/Extra-Chill/wp-coding-agents/issues/425"; fill = "x" * (340 if mode == "largest_success" else 1024); fill = "\\\\" * 400 if mode == "escaping_over_budget" else fill; rows = [{"handle": f"fixture@task-425-{index:03d}", "path": f"{path}/{fill}", "branch": f"fix/425-resolve-task-{index:03d}", "task_full": {"task_url": task}, "safety": {"dirty": False, "unpushed": False, "primary": False}} for index in range(1, 201)]; print(json.dumps({"success": True, "total": 200, "returned": 200, "next_cursor": None, "worktrees": rows}, separators=(",", ":")))' "${DMC_TASK_LOOKUP_MODE:-}" "$DMC_STATE"
      ;;
    incomplete_page)
      printf '{"success":true,"total":201,"returned":200,"next_cursor":"next","worktrees":[]}\n'
      ;;
    overflow)
      printf '{"success":false,"error":{"code":"worktree_task_candidates_overflow","message":"Task worktree lookup exceeded the complete bounded candidate limit.","data":{"status":409,"task_ref":"https://github.com/Extra-Chill/wp-coding-agents/issues/425","total":201,"limit":200}}}\n'
      exit 1
      ;;
    over_budget)
      oversized="$(python3 -c 'print("x" * 4097)')"
      printf '{"success":true,"total":1,"returned":1,"next_cursor":null,"worktrees":[{"handle":"fixture@task-425","path":"%s","branch":"fix/425-resolve-task","task_full":{"task_url":"https://github.com/Extra-Chill/wp-coding-agents/issues/425"},"safety":{"dirty":false,"unpushed":false,"primary":false}}]}\n' "$oversized"
      ;;
    oversized_stdout)
      python3 -c 'import sys; sys.stdout.write("x" * 1048577)'
      ;;
    oversized_stderr)
      python3 -c 'import sys; sys.stderr.write("x" * 65537)'
      ;;
    descendant_both)
      python3 -c 'import os, sys
marker = os.environ["DMC_DESCENDANT_PID"]
open(marker, "w").write(str(os.getpid()))
while True:
    os.write(sys.stdout.fileno(), b"x" * 8192)
    os.write(sys.stderr.fileno(), b"y" * 8192)' &
      wait "$!"
      ;;
    descendant_silent)
      python3 -c 'import os, time
open(os.environ["DMC_DESCENDANT_PID"], "w").write(str(os.getpid()))
while True:
    time.sleep(1)' &
      wait "$!"
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree provider" ]; then
  [ "${DMC_PROVIDER_DISCOVERY_MODE:-}" = diagnostic_prefix ] && printf '\nDeprecated: Case statements followed by a semicolon are deprecated.\n'
  [ "${DMC_PROVIDER_DISCOVERY_MODE:-}" = arbitrary_prefix ] && printf 'unexpected output\n'
  printf '{"schema":"datamachine-code/standalone-worktree-provider-command/v1","executable":"%s"}\n' "$DMC_PROVIDER_EXECUTABLE"
  exit 0
fi
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree attach-tracker" ]; then
  [ "$6" = "static-site-importer@refactor-1306-runtime-entity-form-materialization" ] || exit 2
  case "$*" in
    *--task-url=https://github.com/Automattic/static-site-importer/issues/1306*--format=json*"--path=$SITE_PATH"*) ;;
    *) exit 2 ;;
  esac
  if [ -n "${DMC_ATTACHMENT_ERROR:-}" ]; then
    printf 'dmc-%s\n' "$DMC_ATTACHMENT_ERROR" >&2
    exit 17
  fi
  if [ -f "$DMC_ATTACHMENT_STATE" ]; then status=already_attached; else status=attached; : > "$DMC_ATTACHMENT_STATE"; fi
  printf '{"success":true,"status":"%s","handle":"%s","provider_resolution":{"schema":"datamachine-code/worktree-identity/v1","status":"owned","handle":"%s","path":"%s","branch":"refactor-1306-runtime-entity-form-materialization","primary":false,"task_url":"https://github.com/Automattic/static-site-importer/issues/1306"}}\n' "$status" "$6" "$6" "$DMC_ATTACHMENT_PATH"
  exit 0
fi
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree plan" ]; then
  [ "$6" = "blocks-engine" ] && [ "$7" = "fix/406-dmc-provider-plan" ] || exit 2
  case "$*" in
    *--from=origin/main*--task-url=https://github.com/Extra-Chill/wp-coding-agents/issues/406*--reuse-policy=isolated*--purpose=agent-task-cook*--owner-run-ref=homeboy://agent-task/run/cook-406*--cleanup-policy=remove_on_success*--format=json*) ;;
    *) exit 2 ;;
  esac
  printf 'plan\n' >> "$DMC_ENSURE_LOG"
  if [ -n "${DMC_PLAN_TEXT_DISPOSITION:-}" ]; then
    printf 'Disposition: %s\n' "$DMC_PLAN_TEXT_DISPOSITION"
    exit 9
  fi
  printf '{"version":1,"digest":"fixture-plan-digest","handle":"blocks-engine@fix-406-dmc-provider-plan","path":"%s","branch":"fix/406-dmc-provider-plan","disposition":"%s"}\n' "$DMC_PLAN_PATH" "${DMC_PLAN_DISPOSITION:-create}"
  exit 0
fi
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree add" ]; then
  [ "$6" = "blocks-engine" ] && [ "$7" = "fix/406-dmc-provider-plan" ] || exit 2
  case "$*" in
    *--from=origin/main*--task-url=https://github.com/Extra-Chill/wp-coding-agents/issues/406*--reuse-policy=isolated*--purpose=agent-task-cook*--owner-run-ref=homeboy://agent-task/run/cook-406*--cleanup-policy=remove_on_success*--format=json*) ;;
    *) exit 2 ;;
  esac
  : > "$DMC_STATE"
  printf 'ensure\n' >> "$DMC_ENSURE_LOG"
  printf '{"success":true,"handle":"blocks-engine@fix-406-dmc-provider-plan"}\n'
  exit 0
fi
if [ "$1 $2 $3 $4 $5" = "wp datamachine-code workspace worktree finalize" ]; then
  [ "$6" = "wp-codebox@release-wp-codebox-6b69fc607f7f" ] || exit 2
  case "$*" in
    *--owner-terminal-outcome=success*--format=json*"--path=$SITE_PATH"*|*--owner-terminal-outcome=failure*--format=json*"--path=$SITE_PATH"*) ;;
    *) exit 2 ;;
  esac
  printf '{"success":true,"handle":"%s"}\n' "$6"
  exit 0
fi
exit 2
SH
chmod +x "$FAKE_BIN/studio"

PATH="$FAKE_BIN:$PATH"
HOMEBOY_CONFIG_LOG="$TMP/homeboy-config.log"
STUDIO_LOG="$TMP/studio.log"
DMC_STATE="$DM_WORKSPACE_DIR/fixture@fix-310-dmc-cook"
DMC_ENSURE_LOG="$TMP/dmc-ensure.log"
DMC_PLAN_PATH="$DM_WORKSPACE_DIR/blocks-engine@fix-406-dmc-provider-plan"
DMC_PROVIDER_LOG="$TMP/dmc-provider.log"
DMC_PROVIDER_EXECUTABLE="$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider"
DMC_CHILD_PID="$TMP/dmc-child.pid"
DMC_DESCENDANT_PID="$TMP/dmc-descendant.pid"
DMC_ATTACHMENT_STATE="$TMP/dmc-attachment-state"
DMC_ATTACHMENT_PATH="$DM_WORKSPACE_DIR/static-site-importer@refactor-1306-runtime-entity-form-materialization"
: > "$DMC_ENSURE_LOG"
: > "$STUDIO_LOG"
export HOMEBOY_CONFIG_LOG STUDIO_LOG DMC_STATE DMC_ENSURE_LOG DMC_PLAN_PATH DMC_PROVIDER_LOG DMC_PROVIDER_EXECUTABLE DMC_CHILD_PID DMC_DESCENDANT_PID DMC_ATTACHMENT_STATE DMC_ATTACHMENT_PATH SITE_PATH

# macOS ships Bash 3.2, which has no mapfile/readarray builtin. Disable it
# when the test runs under newer Bash so this path stays portable.
enable -n mapfile 2>/dev/null || true

discovered_provider="$(DMC_PROVIDER_DISCOVERY_MODE=diagnostic_prefix homeboy_dmc_worktree_provider_executable)"
[ "$discovered_provider" = "$DMC_PROVIDER_EXECUTABLE" ] || {
  echo "FAIL: provider discovery rejected a leading PHP diagnostic"
  exit 1
}
if DMC_PROVIDER_DISCOVERY_MODE=arbitrary_prefix homeboy_dmc_worktree_provider_executable >/dev/null 2>&1; then
  echo "FAIL: provider discovery accepted an arbitrary output prefix"
  exit 1
fi

DRY_RUN=true
configure_homeboy_dmc_worktree_provider > "$TMP/dry-run.log"

assert_contains "homeboy config set /worktree_providers/dmc '{\"enabled\":true,\"kind\":\"command\",\"apply_enabled\":true" "$TMP/dry-run.log"
assert_contains "\"resolve_identity\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"identity\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{handle}\"]" "$TMP/dry-run.log"
assert_contains "\"attest_safety\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"safety\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{identity}\"]" "$TMP/dry-run.log"
assert_contains "\"converge\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"converge\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{identity}\",\"{base}\"]" "$TMP/dry-run.log"
assert_contains "\"resolve\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"resolve\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{handle}\"]" "$TMP/dry-run.log"
assert_contains "\"resolve_path\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"resolve\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{path}\"]" "$TMP/dry-run.log"
assert_contains "\"resolve_task\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"resolve_task_standalone\",\"{task_url}\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\"]" "$TMP/dry-run.log"
assert_contains "\"task_attachment_preview\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"task_attachment_preview\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{handle}\",\"{task_url}\"]" "$TMP/dry-run.log"
assert_contains "\"task_attachment_apply\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"task_attachment_apply\",\"{handle}\",\"{task_url}\",\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"attach-tracker\",\"{handle}\",\"--task-url={task_url}\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"resolve_not_found_exit_codes\":[42]" "$TMP/dry-run.log"
assert_contains "\"resolve_task_not_found_exit_codes\":[42]" "$TMP/dry-run.log"
assert_contains "\"ensure\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"add\",\"{repo}\",\"{head}\",\"--from={base}\",\"--task-url={task_url}\",\"--reuse-policy=isolated\",\"--purpose={purpose}\",\"--owner-run-ref={owner_run_ref}\",\"--cleanup-policy={cleanup_policy}\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"plan\":[\"php\",\"$SCRIPT_DIR/scripts/homeboy-dmc-provider.php\",\"plan_standalone\",\"$DMC_PROVIDER_EXECUTABLE\",\"$DM_WORKSPACE_DIR\",\"{repo}\",\"{head}\",\"{base}\",\"{task_url}\",\"{purpose}\",\"{owner_run_ref}\",\"{cleanup_policy}\"]" "$TMP/dry-run.log"
assert_contains "homeboy config set /settings/worktree_provider_lifecycle/dmc/finalize '[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"finalize\",\"{handle}\",\"--owner-terminal-outcome={owner_outcome}\",\"--format=json\",\"--path=$SITE_PATH\"]'" "$TMP/dry-run.log"
assert_not_contains '"list":' "$TMP/dry-run.log"
assert_contains "\"cleanup_preview\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"cleanup\",\"safe\",\"--dry-run\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
assert_contains "\"cleanup_apply\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"cleanup\",\"safe\",\"--format=json\",\"--path=$SITE_PATH\"]" "$TMP/dry-run.log"
if [ -f "$HOMEBOY_CONFIG_LOG" ]; then
  echo "FAIL: dry-run should not call homeboy config set"
  cat "$HOMEBOY_CONFIG_LOG"
  exit 1
fi

DRY_RUN=false

# Readiness runs the generated resolve argv, not just DMC's underlying identity
# executable. Historical and unknown placeholders must fail before config write.
provider_json="$(homeboy_dmc_worktree_provider_json "$DMC_PROVIDER_EXECUTABLE")"
rm -f "$DMC_STATE"
homeboy_dmc_worktree_provider_ready "$DMC_PROVIDER_EXECUTABLE" "$provider_json"
stale_resolve_json="$(printf '%s' "$provider_json" | python3 -c 'import json, sys; provider = json.load(sys.stdin); provider["commands"]["resolve"].append("{repo}"); print(json.dumps(provider, separators=(",", ":")))')"
if homeboy_dmc_worktree_provider_ready "$DMC_PROVIDER_EXECUTABLE" "$stale_resolve_json" 2> "$TMP/stale-resolve-readiness.log"; then
  echo "FAIL: readiness accepted the historical repo-scoped resolve template"
  exit 1
fi
assert_contains 'resolve command contains an unresolved placeholder: {repo}' "$TMP/stale-resolve-readiness.log"
unknown_resolve_json="$(printf '%s' "$provider_json" | python3 -c 'import json, sys; provider = json.load(sys.stdin); provider["commands"]["resolve"].append("{unknown}"); print(json.dumps(provider, separators=(",", ":")))')"
if homeboy_dmc_worktree_provider_ready "$DMC_PROVIDER_EXECUTABLE" "$unknown_resolve_json" 2> "$TMP/unknown-resolve-readiness.log"; then
  echo "FAIL: readiness accepted an unknown resolve placeholder"
  exit 1
fi
assert_contains 'resolve command contains an unresolved placeholder: {unknown}' "$TMP/unknown-resolve-readiness.log"

configure_homeboy_dmc_worktree_provider > "$TMP/apply.log"

assert_contains 'identity|homeboy-readiness@probe' "$DMC_PROVIDER_LOG"
assert_not_contains 'workspace worktree get' "$STUDIO_LOG"
assert_contains "/worktree_providers/dmc|{\"enabled\":true,\"kind\":\"command\",\"apply_enabled\":true" "$HOMEBOY_CONFIG_LOG"
assert_contains "/settings/worktree_provider_lifecycle/dmc/finalize|[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"worktree\",\"finalize\",\"{handle}\",\"--owner-terminal-outcome={owner_outcome}\",\"--format=json\",\"--path=$SITE_PATH\"]" "$HOMEBOY_CONFIG_LOG"
assert_provider_contract "$HOMEBOY_CONFIG_LOG" "$SCRIPT_DIR" "$SITE_PATH"
assert_provisioning_contract "$HOMEBOY_CONFIG_LOG"
assert_finalization_contract "$HOMEBOY_CONFIG_LOG"
assert_not_contains 'workspace worktree plan' "$STUDIO_LOG"
assert_contains 'plan|{' "$DMC_PROVIDER_LOG"
assert_convergence_contract "$HOMEBOY_CONFIG_LOG"
assert_resolution_contract "$HOMEBOY_CONFIG_LOG"
assert_standalone_task_resolution_contract "$HOMEBOY_CONFIG_LOG"
assert_task_attachment_contract "$HOMEBOY_CONFIG_LOG"
assert_not_contains 'wp datamachine-code workspace worktree list fixture --all --full --format=json' "$STUDIO_LOG"
assert_contains "\"cleanup_apply\":[\"studio\",\"wp\",\"datamachine-code\",\"workspace\",\"cleanup\",\"safe\",\"--format=json\",\"--path=$SITE_PATH\"]" "$HOMEBOY_CONFIG_LOG"

# Older DMC capability payloads keep the bounded WordPress lookup adapter.
DMC_CAPABILITIES_MODE=task_legacy
export DMC_CAPABILITIES_MODE
: > "$HOMEBOY_CONFIG_LOG"
: > "$STUDIO_LOG"
rm -f "$DMC_STATE"
configure_homeboy_dmc_worktree_provider > "$TMP/task-legacy.log"
assert_provider_contract "$HOMEBOY_CONFIG_LOG" "$SCRIPT_DIR" "$SITE_PATH" fallback
assert_task_resolution_contract "$HOMEBOY_CONFIG_LOG"
assert_contains 'wp datamachine-code workspace worktree list' "$STUDIO_LOG"
unset DMC_CAPABILITIES_MODE

# A source checkout can expose the provider outside the historical installed-plugin path.
DMC_PROVIDER_EXECUTABLE="$TMP/dmc-source/bin/dmc-worktree-provider"
export DMC_PROVIDER_EXECUTABLE
rm -f "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider"
rm -f "$DMC_STATE"
: > "$HOMEBOY_CONFIG_LOG"
configure_homeboy_dmc_worktree_provider > "$TMP/source-contract.log"
assert_provider_contract "$HOMEBOY_CONFIG_LOG" "$SCRIPT_DIR" "$SITE_PATH"

copied_release_provider="$SITE_PATH/wp-content/plugins/data-machine-code/.wp-coding-agents-releases/0.72.11-deadbeef/bin/dmc-worktree-provider"
[ "$(homeboy_dmc_provider_release_label "$copied_release_provider")" = "0.72.11" ] || {
  echo "FAIL: copied DMC release version was not parsed from the provider path"
  exit 1
}

# Either missing owning contract keeps the legacy provider JSON byte shape: no
# half-configured attachment key is written.
DMC_CAPABILITIES_MODE=legacy
export DMC_CAPABILITIES_MODE
: > "$HOMEBOY_CONFIG_LOG"
configure_homeboy_dmc_worktree_provider > "$TMP/legacy-dmc.log"
assert_not_contains 'task_attachment_preview' "$HOMEBOY_CONFIG_LOG"
assert_not_contains 'task_attachment_apply' "$HOMEBOY_CONFIG_LOG"
assert_contains "DMC provider $DMC_PROVIDER_EXECUTABLE does not advertise datamachine-code/worktree-provider-capabilities/v1 tracker attachment" "$TMP/legacy-dmc.log"
assert_contains "Copied DMC release: unknown. Homeboy: unknown version." "$TMP/legacy-dmc.log"
assert_contains "\"$SCRIPT_DIR/upgrade.sh\" --wp-path \"$SITE_PATH\"" "$TMP/legacy-dmc.log"
assert_contains "workspace worktree attach-tracker <handle> --task-url=<task-url> --format=json --path=\"$SITE_PATH\"" "$TMP/legacy-dmc.log"
unset DMC_CAPABILITIES_MODE

HOMEBOY_ATTACHMENT_COMMANDS=false
export HOMEBOY_ATTACHMENT_COMMANDS
: > "$HOMEBOY_CONFIG_LOG"
configure_homeboy_dmc_worktree_provider > "$TMP/legacy-homeboy.log"
assert_not_contains 'task_attachment_preview' "$HOMEBOY_CONFIG_LOG"
assert_not_contains 'task_attachment_apply' "$HOMEBOY_CONFIG_LOG"
assert_contains "DMC provider $DMC_PROVIDER_EXECUTABLE advertises datamachine-code/worktree-provider-capabilities/v1 tracker attachment" "$TMP/legacy-homeboy.log"
assert_contains "Copied DMC release: unknown. Homeboy: unknown version." "$TMP/legacy-homeboy.log"
assert_contains 'homeboy upgrade' "$TMP/legacy-homeboy.log"
assert_contains "\"$SCRIPT_DIR/upgrade.sh\" --wp-path \"$SITE_PATH\"" "$TMP/legacy-homeboy.log"
unset HOMEBOY_ATTACHMENT_COMMANDS
assert_contains "$DMC_PROVIDER_EXECUTABLE" "$HOMEBOY_CONFIG_LOG"
assert_not_contains "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" "$HOMEBOY_CONFIG_LOG"
: > "$DMC_STATE"
assert_resolution_contract "$HOMEBOY_CONFIG_LOG"

# The same generated set operation is used during upgrade, replacing stale
# installed provider objects rather than retaining incompatible resolve commands.
printf '/worktree_providers/dmc|{"commands":{"resolve":["provider","resolve","{handle}","{repo}"],"ensure":["stale"]}}\n' > "$HOMEBOY_CONFIG_LOG"
rm -f "$DMC_STATE"
configure_homeboy_dmc_worktree_provider > "$TMP/upgrade.log"
assert_provider_contract "$HOMEBOY_CONFIG_LOG" "$SCRIPT_DIR" "$SITE_PATH"

# Failure guidance must replay a full upgrade, which updates DMC before
# reconciling the provider config. --plugins-only deliberately does not.
homeboy_dmc_worktree_provider_ready() { return 1; }
HOMEBOY_CONFIG_LOG="$TMP/readiness-failure-config.log"
export HOMEBOY_CONFIG_LOG
configure_homeboy_dmc_worktree_provider > "$TMP/readiness-failure.log"
assert_contains "rerun: \"$SCRIPT_DIR/upgrade.sh\" --wp-path \"$SITE_PATH\"" "$TMP/readiness-failure.log"
assert_not_contains '--plugins-only' "$TMP/readiness-failure.log"
if [ -f "$HOMEBOY_CONFIG_LOG" ]; then
  echo "FAIL: failed readiness should not write Homeboy provider config"
  cat "$HOMEBOY_CONFIG_LOG"
  exit 1
fi

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
