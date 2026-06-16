#!/bin/bash
# Optional WP AI Gateway integration for OpenCode runtimes.

AI_GATEWAY_PROVIDER_ID="wp-ai-gateway"
AI_GATEWAY_MODEL_ID="${AI_GATEWAY_MODEL_ID:-site-default}"
AI_GATEWAY_ROUTE_PROVIDER="${AI_GATEWAY_ROUTE_PROVIDER:-openai}"
AI_GATEWAY_ROUTE_MODEL="${AI_GATEWAY_ROUTE_MODEL:-gpt-4o-mini}"
AI_GATEWAY_ENV_FILE="${AI_GATEWAY_ENV_FILE:-}"

ai_gateway_enabled_for_opencode() {
  [ "${WITH_AI_GATEWAY:-false}" = true ] || return 1

  local runtime
  for runtime in "${DETECTED_RUNTIMES[@]:-}"; do
    [ "$runtime" = "opencode" ] && return 0
  done

  [ "${RUNTIME:-}" = "opencode" ]
}

ai_gateway_validate_topology() {
  ai_gateway_enabled_for_opencode || return 0

  local route_provider route_model model_provider
  route_provider="$(printf '%s' "$AI_GATEWAY_ROUTE_PROVIDER" | tr '[:upper:]' '[:lower:]')"
  route_model="$AI_GATEWAY_ROUTE_MODEL"
  model_provider=""
  case "$route_model" in
    *:*) model_provider="${route_model%%:*}" ;;
  esac
  model_provider="$(printf '%s' "$model_provider" | tr '[:upper:]' '[:lower:]')"

  case "$route_provider" in
    wp-ai-gateway|ai-gateway|opencode)
      error "Refusing recursive WP AI Gateway topology: OpenCode gateway route provider '$AI_GATEWAY_ROUTE_PROVIDER' would route back toward OpenCode/gateway mode. Choose a backend provider such as openai."
      ;;
  esac

  case "$model_provider" in
    wp-ai-gateway|ai-gateway|opencode)
      error "Refusing recursive WP AI Gateway topology: OpenCode gateway route model '$AI_GATEWAY_ROUTE_MODEL' is provider-qualified back toward OpenCode/gateway mode. Choose a backend model for $AI_GATEWAY_ROUTE_PROVIDER."
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

ai_gateway_env_file() {
  if [ -n "$AI_GATEWAY_ENV_FILE" ]; then
    printf '%s' "$AI_GATEWAY_ENV_FILE"
    return
  fi
  printf '%s/.opencode/wp-ai-gateway.env' "$SITE_PATH"
}

ai_gateway_install_stack() {
  ai_gateway_enabled_for_opencode || return 0

  log "Phase 6.5: Installing WP AI Gateway provider stack..."
  install_plugin ai-provider-for-openai https://github.com/WordPress/ai-provider-for-openai.git
  install_plugin wp-ai-gateway https://github.com/Automattic/wp-ai-gateway.git
}

ai_gateway_configure_wordpress() {
  ai_gateway_enabled_for_opencode || return 0

  log "Configuring WP AI Gateway route: $AI_GATEWAY_ROUTE_PROVIDER / $AI_GATEWAY_ROUTE_MODEL"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD ai-gateway configure $AI_GATEWAY_ROUTE_PROVIDER $AI_GATEWAY_ROUTE_MODEL --path=$SITE_PATH $WP_ROOT_FLAG"
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
    warn "Could not parse WP AI Gateway token output; leaving OpenCode env unchanged"
    return 1
  fi
  printf '%s' "$token"
}

ai_gateway_write_env() {
  ai_gateway_enabled_for_opencode || return 0

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
  UPDATED_ITEMS+=("WP AI Gateway OpenCode env ($env_file)")
}

ai_gateway_configure_opencode() {
  ai_gateway_enabled_for_opencode || return 0

  local config_file env_file base_url
  config_file="$SITE_PATH/opencode.json"
  env_file="$(ai_gateway_env_file)"
  base_url="$(ai_gateway_base_url)"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge WP AI Gateway provider into $config_file"
    echo -e "${BLUE}[dry-run]${NC} Provider: $AI_GATEWAY_PROVIDER_ID/$AI_GATEWAY_MODEL_ID via OPENAI_BASE_URL=$base_url and OPENAI_API_KEY=<redacted>"
    return 0
  fi

  if [ ! -f "$config_file" ]; then
    warn "OpenCode config not found at $config_file — skipping WP AI Gateway provider merge"
    return 0
  fi

  python3 - "$config_file" "$AI_GATEWAY_PROVIDER_ID" "$AI_GATEWAY_MODEL_ID" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider_id = sys.argv[2]
model_id = sys.argv[3]

data = json.loads(path.read_text(encoding="utf-8"))
provider = data.setdefault("provider", {}).setdefault(provider_id, {})
provider.setdefault("name", "WP AI Gateway")
provider.setdefault("npm", "@ai-sdk/openai-compatible")
provider.setdefault("env", ["OPENAI_API_KEY"])
provider.setdefault("options", {})
provider["options"].setdefault("baseURL", "${OPENAI_BASE_URL}")
provider["options"].setdefault("name", "wp-ai-gateway")
models = provider.setdefault("models", {})
model = models.setdefault(model_id, {})
model.setdefault("name", "WP AI Gateway site default")
model.setdefault("id", model_id)
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
  log "OpenCode env file: $env_file"
}

setup_ai_gateway() {
  ai_gateway_enabled_for_opencode || return 0
  ai_gateway_validate_topology
  ai_gateway_install_stack
  ai_gateway_configure_wordpress
  ai_gateway_write_env
}

upgrade_ai_gateway() {
  ai_gateway_enabled_for_opencode || return 0
  ai_gateway_validate_topology
  ai_gateway_install_stack
  ai_gateway_configure_wordpress
  ai_gateway_write_env
}
