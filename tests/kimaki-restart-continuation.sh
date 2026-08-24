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
grep -q '^send --channel 123456789012345678 --prompt Managed upgrade restart continuation\.' "$TMP/kimaki.log"

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

echo "==> mismatched site identity fails closed"
mkdir -p "$TMP/mismatch" "$TMP/other-site"
prepare "$TMP/mismatch" >/dev/null
before="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
TEST_TMP="$TMP" "$HELPER" consume --site-path "$TMP/other-site" --data-dir "$TMP/mismatch/data" --kimaki-bin "$TMP/bin/kimaki" --delay 0 --now 1001 > "$TMP/mismatch/consume.json"
[ "$(json_value "$(state_file "$TMP/mismatch" resume-status.json)" reason)" = site_mismatch ]
after="$(wc -l < "$TMP/kimaki.log" | tr -d ' ')"
[ "$after" = "$before" ]

echo "PASS: tests/kimaki-restart-continuation.sh"
