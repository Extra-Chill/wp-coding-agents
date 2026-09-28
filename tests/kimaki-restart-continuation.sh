#!/bin/bash
# tests/kimaki-restart-continuation.sh — deterministic restart handoff contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SCRIPT_DIR/bridges/kimaki/restart-continuation.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/site" "$TMP/Library/LaunchAgents"
touch "$TMP/Library/LaunchAgents/com.wp.kimaki.plist"

cat > "$TMP/bin/launchctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/launchctl.log"
if [ "$1" = bootstrap ] && [ "${TEST_BOOTSTRAP_FAIL:-false}" = true ]; then
  exit 17
fi
SH
chmod +x "$TMP/bin/launchctl"

cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$TEST_TMP/systemctl.log"
SH
cat > "$TMP/bin/sudo" <<'SH'
#!/bin/sh
[ "$1 $2 $3 $4" = "-n systemctl restart kimaki.service" ] || exit 91
printf 'sudo %s\n' "$*" >> "$TEST_TMP/systemctl.log"
shift
exec "$@"
SH
chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"

cat > "$TMP/bin/kimaki" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/kimaki.log"
sleep "${TEST_SEND_DELAY:-0}"
SH
chmod +x "$TMP/bin/kimaki"

state_file() {
  printf '%s/data/kimaki-config/restart-continuation/%s' "$1" "$2"
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

prepare() {
  local root="$1"
  TEST_TMP="$TMP" PATH="$TMP/bin:/usr/bin:/bin" "$HELPER" restart \
    --mode launchd \
    --target "$TMP/Library/LaunchAgents/com.wp.kimaki.plist" \
    --site-path "$TMP/site" \
    --data-dir "$root/data" \
    --route-id 123456789012345678 \
    --session-id ses_test_123 \
    --continuation-id continuation-test \
    --now 1000 \
    --ttl 300 \
    --foreground
}

echo "==> successful handoff and resume"
mkdir -p "$TMP/success"
prepare "$TMP/success" > "$TMP/success/prepare.json"
[ "$(json_value "$TMP/success/prepare.json" status)" = handoff_accepted ]
[ "$(json_value "$(state_file "$TMP/success" restart-status.json)" status)" = ok ]

restart_calls="$(wc -l < "$TMP/launchctl.log" | tr -d ' ')"
prepare "$TMP/success" > "$TMP/success/repeated-prepare.json"
[ "$(json_value "$TMP/success/repeated-prepare.json" status)" = already_pending ]
[ "$(wc -l < "$TMP/launchctl.log" | tr -d ' ')" = "$restart_calls" ]

pending="$(state_file "$TMP/success" pending.json)"
python3 - "$pending" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["version"] == 1
assert record["route"] == {
    "kind": "discord_thread",
    "id": "123456789012345678",
    "session_id": "ses_test_123",
}
assert record["upgrade"] == {"status": "success"}
assert record["checks"] == ["bridge_status", "managed_plugins", "startup_warnings"]
assert record["next_action"] == "resume_verification"
serialized = json.dumps(record).lower()
for forbidden in ("token", "secret", "prompt", "content"):
    assert forbidden not in serialized
PY

TEST_TMP="$TMP" "$HELPER" consume \
  --site-path "$TMP/site" \
  --data-dir "$TMP/success/data" \
  --kimaki-bin "$TMP/bin/kimaki" \
  --delay 0 \
  --now 1001 > "$TMP/success/consume.json"
[ "$(json_value "$TMP/success/consume.json" status)" = resumed ]
[ "$(json_value "$(state_file "$TMP/success" resume-status.json)" status)" = resumed ]
[ "$(wc -l < "$TMP/kimaki.log" | tr -d ' ')" = 1 ]
grep -q '^send --thread 123456789012345678 --prompt Managed upgrade restart continuation\.' "$TMP/kimaki.log"

echo "==> failed bootstrap retains typed recovery"
mkdir -p "$TMP/bootstrap-fail"
set +e
TEST_BOOTSTRAP_FAIL=true prepare "$TMP/bootstrap-fail" > "$TMP/bootstrap-fail/prepare.json"
bootstrap_rc=$?
set -e
[ "$bootstrap_rc" = 17 ]
restart_status="$(state_file "$TMP/bootstrap-fail" restart-status.json)"
[ "$(json_value "$restart_status" status)" = restart_failed ]
[ "$(json_value "$restart_status" phase)" = bootstrap ]
python3 - "$restart_status" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["recovery_command"][1] == "restart-worker"
assert not any("token" in part.lower() or "secret" in part.lower() for part in value["recovery_command"])
PY
[ -f "$(state_file "$TMP/bootstrap-fail" pending.json)" ]

echo "==> duplicate startup dispatches once"
mkdir -p "$TMP/duplicate"
prepare "$TMP/duplicate" >/dev/null
before="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
TEST_TMP="$TMP" TEST_SEND_DELAY=0.2 "$HELPER" consume --site-path "$TMP/site" --data-dir "$TMP/duplicate/data" --kimaki-bin "$TMP/bin/kimaki" --delay 0 --now 1001 > "$TMP/duplicate/one.json" &
pid_one=$!
TEST_TMP="$TMP" TEST_SEND_DELAY=0.2 "$HELPER" consume --site-path "$TMP/site" --data-dir "$TMP/duplicate/data" --kimaki-bin "$TMP/bin/kimaki" --delay 0 --now 1001 > "$TMP/duplicate/two.json" &
pid_two=$!
wait "$pid_one"
wait "$pid_two"
after="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
[ "$((after - before))" = 1 ]

echo "==> expired continuation fails closed"
mkdir -p "$TMP/expired"
prepare "$TMP/expired" >/dev/null
before="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
TEST_TMP="$TMP" "$HELPER" consume --site-path "$TMP/site" --data-dir "$TMP/expired/data" --kimaki-bin "$TMP/bin/kimaki" --delay 0 --now 1301 > "$TMP/expired/consume.json"
[ "$(json_value "$TMP/expired/consume.json" status)" = rejected ]
[ "$(json_value "$(state_file "$TMP/expired" resume-status.json)" reason)" = expired ]
after="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
[ "$after" = "$before" ]
[ ! -f "$(state_file "$TMP/expired" pending.json)" ]

echo "==> route-kind to kimaki-send-flag mapping (#619 defect 3)"
python3 - "$HELPER" <<'PY'
import importlib.util
import sys

helper_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("restart_continuation", helper_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.send_flag_for_route_kind("discord_thread") == "--thread", \
    "discord_thread routes must dispatch with --thread, not --channel"
assert module.send_flag_for_route_kind("channel") is None, \
    "unrecognized kinds must fail closed rather than guess a flag"
assert module.send_flag_for_route_kind(None) is None
assert module.send_flag_for_route_kind(123) is None
print("  ok   discord_thread -> --thread, unknown kinds -> None (fail closed)")
PY

echo "==> mismatched site identity fails closed"
mkdir -p "$TMP/mismatch" "$TMP/other-site"
prepare "$TMP/mismatch" >/dev/null
before="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
TEST_TMP="$TMP" "$HELPER" consume --site-path "$TMP/other-site" --data-dir "$TMP/mismatch/data" --kimaki-bin "$TMP/bin/kimaki" --delay 0 --now 1001 > "$TMP/mismatch/consume.json"
[ "$(json_value "$(state_file "$TMP/mismatch" resume-status.json)" reason)" = site_mismatch ]
after="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
[ "$after" = "$before" ]

echo "==> root cannot mutate service-user continuation state"
python3 - "$HELPER" "$TMP" <<'PY'
import importlib.util
import os
import pwd
import sys
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("restart_continuation", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
data = Path(sys.argv[2]) / "root-guard-data"
data.mkdir()
args = module.parser().parse_args([
    "restart", "--mode", "systemd", "--target", "kimaki.service",
    "--site-path", str(Path(sys.argv[2]) / "site"), "--data-dir", str(data),
    "--route-id", "123456789012345678",
])
owner = pwd.getpwuid(os.stat(data).st_uid)
with patch.object(module.os, "geteuid", return_value=0), \
     patch.object(module.subprocess, "Popen", side_effect=AssertionError("worker spawned")), \
     patch("builtins.print") as output:
    assert module.prepare(args) == 2
    import json
    diagnostic = json.loads(output.call_args.args[0])
assert diagnostic["reason"] == "service_user_required"
assert diagnostic["required_uid"] == os.stat(data).st_uid
assert diagnostic["required_user"] == owner.pw_name
assert diagnostic["invocation"][:6] == ["sudo", "-n", "-H", "-u", owner.pw_name, "--"]
assert not (data / "kimaki-config").exists()

link = Path(sys.argv[2]) / "root-guard-link"
link.symlink_to(data, target_is_directory=True)
args.data_dir = str(link)
with patch.object(module.os, "geteuid", return_value=0), patch("builtins.print") as output:
    assert module.prepare(args) == 2
assert json.loads(output.call_args.args[0])["reason"] == "untrusted_data_dir"
PY

echo "==> non-root systemd worker retains scoped sudo restart"
python3 - "$HELPER" "$TMP/success/data" <<'PY'
import importlib.util
import subprocess
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("restart_continuation", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
args = module.parser().parse_args([
    "restart-worker", "--mode", "systemd", "--target", "kimaki.service",
    "--data-dir", sys.argv[2], "--delay", "0",
])
with patch.object(module.os, "geteuid", return_value=1000), \
     patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
    assert module.restart_worker(args) == 0
assert run.call_args.args[0] == ["sudo", "-n", "systemctl", "restart", "kimaki.service"]
PY

echo "PASS: tests/kimaki-restart-continuation.sh"
