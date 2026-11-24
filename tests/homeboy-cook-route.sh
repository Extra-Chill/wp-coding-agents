#!/bin/bash
# tests/homeboy-cook-route.sh — Homeboy's Cook route stays served (#815).
#
# Homeboy names the model Cook runs on (agent_task.rotation.entries[].model,
# e.g. roadie/cook-heavy); Pi serves models from the agent dir's models.json,
# which Roadie writes from its credential pool rotations. A Roadie upgrade
# that stopped serving the configured name failed every Cook at admission.
#
# This pins both halves:
#   - the Roadie bridge creates a routed roadie/<rotation> the pool lacks
#     (from the opus rotation's entries, hidden) and never touches one the
#     operator already defined;
#   - the post-upgrade check resolves the daemon's PI_CODING_AGENT_DIR
#     (inline, EnvironmentFile=, or Roadie's pi-agent default) and fails
#     loudly when a routed model is served neither by models.json nor by the
#     pool.
# Homeboy and Roadie are stubs; no real config is read or written.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
PASS=0
check() {
  if [ "$1" -eq 0 ]; then echo "  ok   $2"; PASS=$((PASS + 1)); else echo "  FAIL $2"; FAIL=$((FAIL + 1)); fi
}

STUB="$TMP/bin/roadie"
CALLS="$TMP/calls"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'SH'
#!/bin/bash
# Records argv; implements just enough of `credentials rotation set` to keep
# a real rotation.json (dict form when --hidden, as Roadie stores it).
printf 'argv:'  >> "$ROADIE_STUB_CALLS"; printf ' %s' "$@" >> "$ROADIE_STUB_CALLS"; printf '\n' >> "$ROADIE_STUB_CALLS"
if [ "$1 $2 $3" = "credentials rotation set" ]; then
  name="$4"; shift 4
  models=(); hidden=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool|--description) shift 2 ;;
      --hidden) hidden=true; shift ;;
      *) models+=("$1"); shift ;;
    esac
  done
  mkdir -p "$ROADIE_DATA_DIR/credentials/shared"
  python3 - "$ROADIE_DATA_DIR/credentials/shared/rotation.json" "$name" "$hidden" "${models[@]}" <<'PY'
import json, os, sys
path, name, hidden, models = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4:]
data = json.load(open(path)) if os.path.exists(path) else {}
data[name] = {"entries": models, "hidden": True} if hidden else models
json.dump(data, open(path, "w"))
PY
fi
SH
chmod +x "$STUB"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bridges/roadie.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/homeboy-cook-route.sh"

LOGGED=""
log() { LOGGED="$LOGGED$1
"; }
warn() { LOGGED="$LOGGED$1
"; }

export ROADIE_STUB_CALLS="$CALLS"
ROADIE_BIN="$STUB"
LOCAL_MODE=true
SERVICE_USER=""
SERVICE_HOME="$TMP/home"
ROADIE_DATA_DIR="$SERVICE_HOME/.roadie"
export ROADIE_DATA_DIR
DRY_RUN=false
unset ROADIE_POOL_URL HOMEBOY_PI_AGENT_DIR ROADIE_COOK_ROTATION_MODELS ROADIE_COOK_ROTATION_FALLBACK
UPDATED_ITEMS=()
PENDING_ITEMS=()
ROT="$ROADIE_DATA_DIR/credentials/shared/rotation.json"
mkdir -p "$(dirname "$ROT")" "$ROADIE_DATA_DIR/pi-agent"

# Homeboy stub: `config show /agent_task/rotation/entries` returns the
# command-result envelope Homeboy prints, with HOMEBOY_ENTRIES as the value.
HOMEBOY_ENTRIES='[{"backend":"pi","model":"roadie/cook-heavy","selector":"pi.agent-task-executor"}]'
homeboy_run() {
  [ "$*" = "config show /agent_task/rotation/entries" ] || return 1
  [ -n "$HOMEBOY_ENTRIES" ] || return 1
  printf '{"schema":"homeboy/command-result/v3","success":true,"data":{"pointer":"/agent_task/rotation/entries","value":%s}}\n' "$HOMEBOY_ENTRIES"
}
UNIT="$TMP/systemd/homeboy-daemon.service"
homeboy_daemon_unit_path() { printf '%s\n' "$UNIT"; }

write_pool() { printf '%s\n' "$1" > "$ROT"; }
write_models() {
  python3 - "$1/models.json" "${@:2}" <<'PY'
import json, sys
path, ids = sys.argv[1], sys.argv[2:]
json.dump({"providers": {"roadie": {"baseUrl": "http://127.0.0.1", "models": [{"id": i} for i in ids]}}}, open(path, "w"))
PY
}
reset() { : > "$CALLS"; LOGGED=""; UPDATED_ITEMS=(); PENDING_ITEMS=(); }

echo "==> Homeboy route models"
[ "$(homeboy_cook_route_models)" = "roadie/cook-heavy" ]; check $? "reads the Pi rotation model from Homeboy's config"
HOMEBOY_ENTRIES='[{"backend":"pi","model":"roadie/a"},{"backend":"claude","model":"x/y"},{"backend":"pi","model":"roadie/a"},{"model":"roadie/b"}]'
[ "$(homeboy_cook_route_models | tr '\n' ' ')" = "roadie/a roadie/b " ]; check $? "Pi entries only, deduplicated, in order"
HOMEBOY_ENTRIES=''
[ -z "$(homeboy_cook_route_models)" ]; check $? "no rotation configured prints nothing"
HOMEBOY_ENTRIES='[{"backend":"pi","model":"roadie/cook-heavy","selector":"pi.agent-task-executor"}]'

echo "==> Pi agent dir the daemon uses"
[ "$(homeboy_cook_route_pi_agent_dir)" = "$ROADIE_DATA_DIR/pi-agent" ]; check $? "defaults to Roadie's pi-agent dir without a daemon unit"
mkdir -p "$TMP/systemd"
printf '[Service]\nEnvironment="HOME=/x" "PI_CODING_AGENT_DIR=/inline/agent"\n' > "$UNIT"
[ "$(homeboy_cook_route_pi_agent_dir)" = "/inline/agent" ]; check $? "reads an inline Environment= PI_CODING_AGENT_DIR"
printf 'PI_CODING_AGENT_DIR=/from/envfile\n' > "$TMP/daemon.env"
printf '[Service]\nEnvironment="PI_CODING_AGENT_DIR=/inline/agent"\nEnvironmentFile=-%s\n' "$TMP/daemon.env" > "$UNIT"
[ "$(homeboy_cook_route_pi_agent_dir)" = "/from/envfile" ]; check $? "an EnvironmentFile= (#870) wins over Environment=, '-' prefix tolerated"
printf '[Service]\nEnvironmentFile=-%s/missing.env\n' "$TMP" > "$UNIT"
[ "$(homeboy_cook_route_pi_agent_dir)" = "$ROADIE_DATA_DIR/pi-agent" ]; check $? "a missing optional EnvironmentFile falls back to Roadie's dir"
[ "$(HOMEBOY_PI_AGENT_DIR=/override homeboy_cook_route_pi_agent_dir)" = "/override" ]; check $? "HOMEBOY_PI_AGENT_DIR overrides everything"
rm -f "$UNIT"

echo "==> bridge: a routed rotation the pool lacks is created from opus"
reset
write_pool '{"opus":["anthropic/claude-opus-5-5","openai/gpt-6.1-sol"],"small":["anthropic/claude-sonnet-5-5"]}'
_roadie_ensure_cook_rotations; check $? "ensure succeeds"
grep -q "^argv: credentials rotation set cook-heavy anthropic/claude-opus-5-5 openai/gpt-6.1-sol --pool shared --hidden --description " "$CALLS"
check $? "creates cook-heavy, hidden, from opus's entries in order"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["cook-heavy"]["entries"]==["anthropic/claude-opus-5-5","openai/gpt-6.1-sol"] and d["opus"]==["anthropic/claude-opus-5-5","openai/gpt-6.1-sol"] else 1)' "$ROT"
check $? "pool now defines cook-heavy; opus untouched"
printf '%s\n' "${UPDATED_ITEMS[@]}" | grep -q "Roadie rotation cook-heavy"; check $? "creation is reported in the summary"

echo "==> bridge: an operator-defined rotation is never touched"
reset
write_pool '{"opus":["anthropic/claude-opus-5-5"],"cook-heavy":{"entries":["openai/gpt-6.1-sol"],"hidden":true}}'
_roadie_ensure_cook_rotations; check $? "ensure succeeds"
[ ! -s "$CALLS" ]; check $? "existing cook-heavy is not rewritten"
[ "${#UPDATED_ITEMS[@]}" -eq 0 ]; check $? "nothing reported"

echo "==> bridge: explicit entries, missing fallback, dry run, remote pool, non-roadie routes"
reset
write_pool '{"opus":["anthropic/claude-opus-5-5"]}'
ROADIE_COOK_ROTATION_MODELS="openai/gpt-6.1-sol anthropic/claude-opus-5-5" _roadie_ensure_cook_rotations
grep -q "^argv: credentials rotation set cook-heavy openai/gpt-6.1-sol anthropic/claude-opus-5-5 --pool shared --hidden" "$CALLS"
check $? "ROADIE_COOK_ROTATION_MODELS defines the entries"
reset
write_pool '{"small":["anthropic/claude-sonnet-5-5"]}'
_roadie_ensure_cook_rotations; check $? "no fallback is not fatal"
[ ! -s "$CALLS" ]; check $? "no rotation invented without a fallback"
printf '%s' "$LOGGED" | grep -q "roadie credentials rotation set cook-heavy"; check $? "warns with the command to define it"
reset
ROADIE_COOK_ROTATION_FALLBACK=small _roadie_ensure_cook_rotations
grep -q "^argv: credentials rotation set cook-heavy anthropic/claude-sonnet-5-5 " "$CALLS"; check $? "ROADIE_COOK_ROTATION_FALLBACK picks the source rotation"
reset
write_pool '{"opus":["anthropic/claude-opus-5-5"]}'
DRY_RUN=true _roadie_ensure_cook_rotations
[ ! -s "$CALLS" ]; check $? "dry run writes nothing"
printf '%s' "$LOGGED" | grep -q "Would create Roadie rotation cook-heavy"; check $? "dry run says what it would create"
reset
ROADIE_POOL_URL=https://pool.example _roadie_ensure_cook_rotations
[ ! -s "$CALLS" ]; check $? "a remote pool's rotations are left to the pool host"
reset
HOMEBOY_ENTRIES='[{"backend":"pi","model":"anthropic/claude-opus-5-5"}]' _roadie_ensure_cook_rotations
[ ! -s "$CALLS" ]; check $? "a non-roadie route creates no rotation"

echo "==> check: served route passes"
AGENT="$ROADIE_DATA_DIR/pi-agent"
reset
write_pool '{"opus":["anthropic/claude-opus-5-5"],"cook-heavy":["anthropic/claude-opus-5-5"]}'
write_models "$AGENT" opus small sol cook-heavy
homeboy_cook_route_check; check $? "route served by models.json passes"
printf '%s' "$LOGGED" | grep -q "roadie/cook-heavy served by $AGENT"; check $? "reports the agent dir that serves it"

echo "==> check: defined in the pool but not yet published is pending, not failed"
reset
write_models "$AGENT" opus small sol
homeboy_cook_route_check; check $? "pending publication does not fail the upgrade"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -q "Restart Roadie so Pi serves roadie/cook-heavy"; check $? "asks for a Roadie restart"

echo "==> check: the #815 state fails loudly"
reset
write_pool '{"opus":["anthropic/claude-opus-5-5"],"small":["x/y"],"sol":["x/z"]}'
homeboy_cook_route_check; rc=$?
[ "$rc" -ne 0 ]; check $? "route served by neither models.json nor the pool fails"
printf '%s' "$LOGGED" | grep -q "Cook route BROKEN: Homeboy routes Cooks to roadie/cook-heavy"; check $? "names the broken route"
printf '%s' "$LOGGED" | grep -q "Served by $AGENT: opus small sol"; check $? "lists what the agent dir does serve"
reset
write_pool '{"cook-heavy":["anthropic/claude-opus-5-5"]}'
ROADIE_POOL_URL=https://pool.example homeboy_cook_route_check; rc=$?
[ "$rc" -ne 0 ]; check $? "a remote pool's local rotation file does not mask a missing route"

echo "==> check: the daemon's own agent dir is the one checked (#870)"
reset
write_pool '{"cook-heavy":["anthropic/claude-opus-5-5"]}'
write_models "$AGENT" cook-heavy
mkdir -p "$TMP/daemon-agent" "$TMP/systemd"
write_models "$TMP/daemon-agent" opus
printf 'PI_CODING_AGENT_DIR=%s/daemon-agent\n' "$TMP" > "$TMP/daemon.env"
printf '[Service]\nEnvironmentFile=%s\n' "$TMP/daemon.env" > "$UNIT"
homeboy_cook_route_check; rc=$?
[ "$rc" -ne 0 ]; check $? "fails when the daemon's dir lacks the route even if Roadie's dir and pool have it"
printf '%s' "$LOGGED" | grep -q "$TMP/daemon-agent/models.json does not serve it"; check $? "names the daemon's agent dir"
rm -f "$UNIT"

echo "==> check: unreadable models.json, built-ins, no route, dry run"
reset
rm -f "$AGENT/models.json"
homeboy_cook_route_check; check $? "unreadable models.json warns instead of failing"
printf '%s\n' "${PENDING_ITEMS[@]}" | grep -q "confirm $AGENT/models.json serves roadie/cook-heavy"; check $? "records a pending confirmation"
reset
write_models "$AGENT" opus
HOMEBOY_ENTRIES='[{"backend":"pi","model":"anthropic/claude-opus-5-5"}]' homeboy_cook_route_check; check $? "a Pi built-in provider is not judged by models.json"
reset
HOMEBOY_ENTRIES='' homeboy_cook_route_check; check $? "no Homeboy rotation is a no-op"
reset
write_pool '{}'
DRY_RUN=true homeboy_cook_route_check; check $? "dry run skips the check"

echo "==> wiring"
grep -q 'homeboy homeboy-cook-route' "$SCRIPT_DIR/upgrade.sh"; check $? "upgrade.sh sources lib/homeboy-cook-route.sh"
grep -q 'homeboy homeboy-cook-route' "$SCRIPT_DIR/setup.sh"; check $? "setup.sh sources lib/homeboy-cook-route.sh"
grep -q 'homeboy_cook_route_check || COOK_ROUTE_EXIT_STATUS' "$SCRIPT_DIR/upgrade.sh"; check $? "upgrade.sh runs the post-upgrade check"
grep -q 'COOK_ROUTE_EXIT_STATUS" -ne 0' "$SCRIPT_DIR/upgrade.sh"; check $? "a broken route fails the upgrade"
awk '/^bridge_sync_config\(\)/,/^}/' "$SCRIPT_DIR/bridges/roadie.sh" | grep -q '_roadie_ensure_cook_rotations'; check $? "Roadie sync ensures the Cook rotations"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
