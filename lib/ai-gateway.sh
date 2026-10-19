#!/bin/bash
# Optional WP AI Gateway integration for agent runtimes.
#
# Pi (Roadie's coding runtime) is the active consumer: setup/upgrade merge a
# gateway provider into Pi's models.json and the Roadie unit's ROADIE_PI_MODEL
# points at it. An OpenCode config still present on a host gets the same
# provider merged for continuity, but OpenCode no longer gates the feature.

AI_GATEWAY_PROVIDER_ID="${AI_GATEWAY_PROVIDER_ID:-wp-ai-gateway}"
AI_GATEWAY_MODEL_ID="${AI_GATEWAY_MODEL_ID:-site-default}"
AI_GATEWAY_API_MODEL_ID="${AI_GATEWAY_API_MODEL_ID:-}"
AI_GATEWAY_ROUTE_PROVIDER="${AI_GATEWAY_ROUTE_PROVIDER:-openai}"
AI_GATEWAY_ROUTE_MODEL="${AI_GATEWAY_ROUTE_MODEL:-gpt-4o-mini}"
AI_GATEWAY_ENV_FILE="${AI_GATEWAY_ENV_FILE:-}"

# The gateway is a host-level opt-in: --with-ai-gateway alone decides. The
# retired OpenCode-only runtime gate is gone (#774); Pi runs behind Roadie and
# Homeboy regardless of the legacy RUNTIME selector.
ai_gateway_enabled() {
  [ "${WITH_AI_GATEWAY:-false}" = true ]
}

ai_gateway_validate_topology() {
  ai_gateway_enabled || return 0

  local route_provider route_model model_provider
  route_provider="$(printf '%s' "$AI_GATEWAY_ROUTE_PROVIDER" | tr '[:upper:]' '[:lower:]')"
  route_model="$AI_GATEWAY_ROUTE_MODEL"
  model_provider=""
  case "$route_model" in
    *:*) model_provider="${route_model%%:*}" ;;
  esac
  model_provider="$(printf '%s' "$model_provider" | tr '[:upper:]' '[:lower:]')"

  case "$route_provider" in
    wp-ai-gateway|ai-gateway|opencode|pi|roadie)
      error "Refusing recursive WP AI Gateway topology: gateway route provider '$AI_GATEWAY_ROUTE_PROVIDER' would route back toward the agent runtime/gateway. Choose a backend provider such as openai."
      ;;
  esac

  case "$model_provider" in
    wp-ai-gateway|ai-gateway|opencode|pi|roadie)
      error "Refusing recursive WP AI Gateway topology: gateway route model '$AI_GATEWAY_ROUTE_MODEL' is provider-qualified back toward the agent runtime/gateway. Choose a backend model for $AI_GATEWAY_ROUTE_PROVIDER."
      ;;
  esac
}

ai_gateway_base_url() {
  local site_url="${AI_GATEWAY_SITE_URL:-}"
  if [ -z "$site_url" ]; then
    if [ -n "${SITE_DOMAIN:-}" ]; then
      case "$SITE_DOMAIN" in
        http://*|https://*) site_url="$SITE_DOMAIN" ;;
        *) site_url="https://$SITE_DOMAIN" ;;
      esac
    else
      site_url="https://example.com"
    fi
  fi

  printf '%s/wp-json/wp-ai-gateway/v1' "${site_url%/}"
}

ai_gateway_api_model_id() {
  printf '%s' "${AI_GATEWAY_API_MODEL_ID:-$AI_GATEWAY_MODEL_ID}"
}

# The Pi model selector for gateway-backed sessions, as Roadie expects it in
# ROADIE_PI_MODEL: "<provider>/<model>". Pi resolves it against the provider
# entry ai_gateway_configure_pi writes into its models.json, so both sides use
# the same model id (the one the gateway actually serves).
ai_gateway_pi_model() {
  printf '%s/%s' "$AI_GATEWAY_PROVIDER_ID" "$(ai_gateway_api_model_id)"
}

# The agent dir Roadie runs Pi against (PI_CODING_AGENT_DIR in _roadie_pi_run
# and Roadie's own session spawns). Roadie's credential pool rewrites only the
# roadie/roadie-* providers in this dir's models.json, so a gateway provider
# merged here survives Roadie's own rewrites.
ai_gateway_pi_agent_dir() {
  if [ -n "${AI_GATEWAY_PI_AGENT_DIR:-}" ]; then
    printf '%s' "$AI_GATEWAY_PI_AGENT_DIR"
    return
  fi
  printf '%s/pi-agent' "${ROADIE_DATA_DIR:-${SERVICE_HOME:-$HOME}/.roadie}"
}

ai_gateway_env_file() {
  if [ -n "$AI_GATEWAY_ENV_FILE" ]; then
    printf '%s' "$AI_GATEWAY_ENV_FILE"
    return
  fi
  printf '%s/.opencode/wp-ai-gateway.env' "$SITE_PATH"
}

ai_gateway_install_stack() {
  ai_gateway_enabled || return 0

  log "Phase 6.5: Installing WP AI Gateway provider stack..."
  install_plugin ai-provider-for-openai https://github.com/WordPress/ai-provider-for-openai.git
  install_plugin wp-ai-gateway https://github.com/Automattic/wp-ai-gateway.git
}

ai_gateway_configure_wordpress() {
  ai_gateway_enabled || return 0

  log "Configuring WP AI Gateway route: $AI_GATEWAY_ROUTE_PROVIDER / $AI_GATEWAY_ROUTE_MODEL"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $(wp_cli_transport_display) ai-gateway configure $AI_GATEWAY_ROUTE_PROVIDER $AI_GATEWAY_ROUTE_MODEL --path=$SITE_PATH $WP_ROOT_FLAG"
    return 0
  fi

  wp_cmd ai-gateway configure "$AI_GATEWAY_ROUTE_PROVIDER" "$AI_GATEWAY_ROUTE_MODEL"
}

ai_gateway_read_env_value() {
  local key="$1" file="$2" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
      export\ "$key"=*) printf '%s' "${line#export $key=}"; return 0 ;;
    esac
  done < "$file"
}

ai_gateway_mint_token() {
  local token_output token
  token_output=$(wp_cmd ai-gateway token 2>&1)
  token=$(printf '%s\n' "$token_output" | grep '^wpag_' | tail -1 || true)
  if [ -z "$token" ]; then
    warn "Could not parse WP AI Gateway token output; leaving gateway env unchanged"
    return 1
  fi
  printf '%s' "$token"
}

ai_gateway_write_env() {
  ai_gateway_enabled || return 0

  local env_file token base_url existing_token
  env_file="$(ai_gateway_env_file)"
  base_url="$(ai_gateway_base_url)"
  existing_token="$(ai_gateway_read_env_value OPENAI_API_KEY "$env_file")"

  if [ -n "$existing_token" ] && [ "${ROTATE_AI_GATEWAY_TOKEN:-false}" != true ]; then
    log "Reusing existing WP AI Gateway token reference at $env_file"
    token="$existing_token"
  elif [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would mint a WP AI Gateway token and write OPENAI_API_KEY to $env_file (redacted)"
    echo -e "${BLUE}[dry-run]${NC} Would write OPENAI_BASE_URL=$base_url to $env_file"
    return 0
  else
    token="$(ai_gateway_mint_token)" || return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

  mkdir -p "$(dirname "$env_file")"
  {
    printf 'OPENAI_BASE_URL=%s\n' "$base_url"
    printf 'OPENAI_API_KEY=%s\n' "$token"
  } > "$env_file"
  chmod 600 "$env_file"
  if [ "${LOCAL_MODE:-false}" = false ] && [ -n "${SERVICE_USER:-}" ]; then
    chown "$SERVICE_USER:$SERVICE_USER" "$env_file" 2>/dev/null || true
  fi
  UPDATED_ITEMS+=("WP AI Gateway env ($env_file)")
}

# Merge the gateway provider into Pi's models.json (the agent dir Roadie runs
# Pi against). The entry references the env file's OPENAI_API_KEY, so token
# rotation never has to touch models.json, and the base URL is refreshed every
# run so an endpoint override (AI_GATEWAY_SITE_URL, #357) always wins.
ai_gateway_configure_pi() {
  ai_gateway_enabled || return 0

  local agent_dir models_file base_url api_model_id
  agent_dir="$(ai_gateway_pi_agent_dir)"
  models_file="$agent_dir/models.json"
  base_url="$(ai_gateway_base_url)"
  api_model_id="$(ai_gateway_api_model_id)"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge WP AI Gateway provider into $models_file"
    echo -e "${BLUE}[dry-run]${NC} Pi provider: $AI_GATEWAY_PROVIDER_ID (model: $api_model_id) via baseUrl=$base_url and apiKey=\$OPENAI_API_KEY"
    return 0
  fi

  mkdir -p "$agent_dir"
  python3 - "$models_file" "$AI_GATEWAY_PROVIDER_ID" "$api_model_id" "$base_url" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider_id = sys.argv[2]
model_id = sys.argv[3]
base_url = sys.argv[4]

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    data = {}

providers = data.setdefault("providers", {})
provider = providers.setdefault(provider_id, {})
provider.setdefault("name", "WP AI Gateway")
provider["baseUrl"] = base_url
provider.setdefault("api", "openai-completions")
# Env reference: Pi resolves $OPENAI_API_KEY from the service environment
# (the gateway env file), so the minted token never lands in models.json.
provider.setdefault("apiKey", "$OPENAI_API_KEY")
models = provider.setdefault("models", [])
model = next((m for m in models if isinstance(m, dict) and m.get("id") == model_id), None)
if model is None:
    model = {"id": model_id}
    models.append(model)
model.setdefault("name", "WP AI Gateway site default")
model.setdefault("input", ["text"])
model.setdefault("contextWindow", 128000)
model.setdefault("maxTokens", 8192)
model.setdefault("cost", {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0})

path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  chmod 600 "$models_file"
  if [ "${LOCAL_MODE:-false}" = false ] && [ -n "${SERVICE_USER:-}" ]; then
    chown "$SERVICE_USER:$SERVICE_USER" "$agent_dir" "$models_file" 2>/dev/null || true
  fi
  UPDATED_ITEMS+=("Pi models.json WP AI Gateway provider ($models_file)")
  log "Merged WP AI Gateway provider into $models_file (Pi model: $(ai_gateway_pi_model))"
}

ai_gateway_configure_opencode() {
  ai_gateway_enabled || return 0

  local config_file env_file base_url api_model_id
  config_file="$SITE_PATH/opencode.json"
  env_file="$(ai_gateway_env_file)"
  base_url="$(ai_gateway_base_url)"
  api_model_id="$(ai_gateway_api_model_id)"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge WP AI Gateway provider into $config_file"
    echo -e "${BLUE}[dry-run]${NC} Provider: $AI_GATEWAY_PROVIDER_ID/$AI_GATEWAY_MODEL_ID (API model: $api_model_id) via OPENAI_BASE_URL=$base_url and OPENAI_API_KEY=<redacted>"
    return 0
  fi

  if [ ! -f "$config_file" ]; then
    # Expected on Pi-only hosts: OpenCode is retired here, and the gateway
    # reaches Pi through ai_gateway_configure_pi instead.
    log "No OpenCode config at $config_file — skipping OpenCode gateway provider merge"
    return 0
  fi

  python3 - "$config_file" "$AI_GATEWAY_PROVIDER_ID" "$AI_GATEWAY_MODEL_ID" "$api_model_id" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider_id = sys.argv[2]
model_id = sys.argv[3]
api_model_id = sys.argv[4]

data = json.loads(path.read_text(encoding="utf-8"))
provider = data.setdefault("provider", {}).setdefault(provider_id, {})
provider.setdefault("name", "WP AI Gateway")
if provider_id == "openai":
    provider["npm"] = "@ai-sdk/openai"
else:
    provider.setdefault("npm", "@ai-sdk/openai-compatible")
provider.setdefault("env", ["OPENAI_API_KEY"])
provider.setdefault("options", {})
provider["options"].setdefault("baseURL", "{env:OPENAI_BASE_URL}")
provider["options"].setdefault("name", "wp-ai-gateway")
models = provider.setdefault("models", {})
model = models.setdefault(model_id, {})
model.setdefault("name", "WP AI Gateway site default")
model["id"] = api_model_id
model.setdefault("tool_call", True)
model.setdefault("temperature", True)
model.setdefault("limit", {"context": 128000, "output": 8192})
model.setdefault("cost", {"input": 0, "output": 0})

if not data.get("model"):
    data["model"] = f"{provider_id}/{model_id}"

path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

  UPDATED_ITEMS+=("opencode.json WP AI Gateway provider")
  log "Merged WP AI Gateway provider into $config_file"
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    log "OpenCode gateway credentials: runtime environment (OPENAI_BASE_URL and OPENAI_API_KEY)"
  else
    log "OpenCode env file: $env_file"
  fi
}

# Setup and upgrade converged on the same steps long ago; they were still two
# identically-bodied functions, which reads as "these differ somehow" to anyone
# who has not diffed them. One name, called from both.
ai_gateway_apply() {
  ai_gateway_enabled || return 0
  ai_gateway_validate_topology
  ai_gateway_install_stack
  ai_gateway_configure_wordpress
  ai_gateway_write_env
  ai_gateway_configure_pi
}
