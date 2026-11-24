#!/bin/bash
# Homeboy Cook route vs. the Pi agent dir that serves it (#815).
#
# Homeboy names the model Cook runs on in one place
# (agent_task.rotation.entries[].model, e.g. `roadie/cook-heavy`), and Pi
# serves models from another: the agent dir's models.json, which Roadie
# rewrites from its credential pool rotations on every start. A Roadie upgrade
# that stopped serving the configured name left every Cook failing admission
# with model_not_available, and nothing noticed until the next Cook.
#
# This file owns the consuming-side facts and the post-upgrade check:
#   - which models Homeboy's rotation routes Pi Cooks to (read from Homeboy);
#   - which agent dir the Homeboy daemon runs Pi against;
#   - whether that dir's models.json serves every routed model.
# The serving side (creating a missing roadie/<rotation> in the pool) lives
# in the Roadie bridge, which owns the pool.

# The agent dir Homeboy's Pi Cooks resolve models against, in order:
#   1. HOMEBOY_PI_AGENT_DIR (explicit operator/test override);
#   2. PI_CODING_AGENT_DIR from the homeboy-daemon unit, inline or through an
#      EnvironmentFile= it reads (a dedicated daemon agent dir, #870);
#   3. Roadie's own agent dir, the one Roadie's pool writes models.json into.
homeboy_cook_route_pi_agent_dir() {
  if [ -n "${HOMEBOY_PI_AGENT_DIR:-}" ]; then
    printf '%s\n' "$HOMEBOY_PI_AGENT_DIR"
    return 0
  fi
  local unit_path="" from_unit=""
  if declare -F homeboy_daemon_unit_path >/dev/null 2>&1; then
    unit_path="$(homeboy_daemon_unit_path)"
  fi
  if [ -n "$unit_path" ] && [ -r "$unit_path" ]; then
    from_unit="$(python3 - "$unit_path" <<'PY' 2>/dev/null || true
import shlex, sys

def assignments(text):
    for word in shlex.split(text, posix=True):
        if "=" in word:
            key, value = word.split("=", 1)
            yield key, value

found = ""
env_files = []
with open(sys.argv[1]) as unit:
    for raw in unit:
        line = raw.strip()
        if line.startswith("Environment="):
            for key, value in assignments(line[len("Environment="):]):
                if key == "PI_CODING_AGENT_DIR":
                    found = value
        elif line.startswith("EnvironmentFile="):
            env_files.append(line[len("EnvironmentFile="):].strip().lstrip("-"))
# systemd applies EnvironmentFile= after Environment=; a later file wins.
for path in env_files:
    try:
        with open(path) as handle:
            for raw in handle:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):]
                for key, value in assignments(line):
                    if key == "PI_CODING_AGENT_DIR":
                        found = value
    except OSError:
        pass
print(found)
PY
)"
  fi
  if [ -n "$from_unit" ]; then
    printf '%s\n' "$from_unit"
    return 0
  fi
  printf '%s/pi-agent\n' "${ROADIE_DATA_DIR:-${SERVICE_HOME:-$HOME}/.roadie}"
}

# Print the model of every Pi entry in Homeboy's Cook rotation, one per line.
# Reads Homeboy's own config through the CLI (never the file directly), as
# the service user. Prints nothing when Homeboy is absent or has no rotation.
homeboy_cook_route_models() {
  declare -F homeboy_run >/dev/null 2>&1 || return 0
  local config
  config="$(homeboy_run config show /agent_task/rotation/entries 2>/dev/null)" || return 0
  printf '%s' "$config" | python3 -c '
import json, sys
try:
    result = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
data = result.get("data", result) if isinstance(result, dict) else {}
entries = data.get("value", data) if isinstance(data, dict) else data
if not isinstance(entries, list):
    sys.exit(0)
seen = set()
for entry in entries:
    if not isinstance(entry, dict) or entry.get("backend", "pi") != "pi":
        continue
    model = entry.get("model")
    if isinstance(model, str) and "/" in model and model not in seen:
        seen.add(model)
        print(model)
' 2>/dev/null || true
}

# Print every provider/model the agent dir's models.json serves.
homeboy_cook_route_served_models() {
  local agent_dir="$1"
  python3 - "$agent_dir/models.json" <<'PY' 2>/dev/null
import json, sys
try:
    providers = json.load(open(sys.argv[1])).get("providers") or {}
except (OSError, ValueError, AttributeError):
    sys.exit(1)
for provider, config in providers.items():
    for model in (config or {}).get("models") or []:
        if isinstance(model, dict) and model.get("id"):
            print(f"{provider}/{model['id']}")
PY
}

# Print every provider models.json declares (a model under a provider it does
# not declare is one of Pi's built-ins, which this check cannot see).
homeboy_cook_route_served_providers() {
  python3 - "$1/models.json" <<'PY' 2>/dev/null
import json, sys
try:
    providers = json.load(open(sys.argv[1])).get("providers") or {}
except (OSError, ValueError, AttributeError):
    sys.exit(1)
for provider in providers:
    print(provider)
PY
}

# Post-upgrade check: every Pi model Homeboy's Cook rotation routes to must be
# served by the agent dir the daemon runs Pi against. The equivalent of the
# model gate `homeboy agent-task cook --preview` applies at admission, run
# here so a missing route fails the upgrade instead of the next Cook.
#
# A roadie/<rotation> the pool already defines but models.json does not list
# yet is only waiting for Roadie to restart (Roadie writes models.json on
# start): reported as pending, not failed, when the daemon uses Roadie's own
# agent dir. Returns 1 when a routed model is
# served by neither.
homeboy_cook_route_check() {
  [ "${DRY_RUN:-false}" = true ] && return 0
  local models agent_dir roadie_dir served providers model provider name missing=0
  models="$(homeboy_cook_route_models)"
  [ -n "$models" ] || return 0
  agent_dir="$(homeboy_cook_route_pi_agent_dir)"
  roadie_dir="${ROADIE_DATA_DIR:-${SERVICE_HOME:-$HOME}/.roadie}/pi-agent"
  if ! served="$(homeboy_cook_route_served_models "$agent_dir")"; then
    warn "Homeboy Cook route: $agent_dir/models.json is missing or unreadable; cannot confirm Pi serves: $(printf '%s' "$models" | tr '\n' ' ')"
    PENDING_ITEMS+=("Homeboy Cook route: confirm $agent_dir/models.json serves $(printf '%s' "$models" | tr '\n' ' ')")
    return 0
  fi
  providers="$(homeboy_cook_route_served_providers "$agent_dir")"
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    provider="${model%%/*}"
    name="${model#*/}"
    if printf '%s\n' "$served" | grep -Fxq -- "$model"; then
      log "  Homeboy Cook route: $model served by $agent_dir"
      continue
    fi
    if ! printf '%s\n' "$providers" | grep -Fxq -- "$provider"; then
      log "  Homeboy Cook route: $model is a Pi built-in provider; not checked against $agent_dir"
      continue
    fi
    # Roadie only republishes its own agent dir; a dedicated daemon dir (#870)
    # is not refreshed by a Roadie restart, so it gets no pending pass.
    if [ "$agent_dir" = "$roadie_dir" ] && \
       declare -F homeboy_cook_route_pool_defines >/dev/null 2>&1 && \
       homeboy_cook_route_pool_defines "$model"; then
      warn "Homeboy Cook route: $model is defined in the Roadie pool but $agent_dir/models.json does not serve it yet; restart Roadie to publish it."
      PENDING_ITEMS+=("Restart Roadie so Pi serves $model (Homeboy Cook route)")
      continue
    fi
    warn "Homeboy Cook route BROKEN: Homeboy routes Cooks to $model, but $agent_dir/models.json does not serve it. Every Cook will fail admission (model_not_available)."
    warn "  Serve it:   roadie credentials rotation set $name <provider/model>... --hidden   (then restart Roadie)"
    warn "  Or reroute: homeboy config set /agent_task/rotation/entries/<n>/model '\"$provider/<served rotation>\"'"
    warn "  Served by $agent_dir: $(printf '%s\n' "$served" | grep "^$provider/" | sed "s|^$provider/||" | tr '\n' ' ')"
    missing=1
  done <<< "$models"
  return "$missing"
}
