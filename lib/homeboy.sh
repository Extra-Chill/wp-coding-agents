#!/bin/bash
# Homeboy project registration plus optional WordPress extension readiness.

HOMEBOY_EXTENSIONS_SOURCE_DEFAULT="https://github.com/Extra-Chill/homeboy-extensions.git"
HOMEBOY_WORDPRESS_READY=false

homeboy_slugify() {
  printf '%s' "$1" | sed 's|https\?://||; s|/.*$||; s|\..*$||' | \
    tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

homeboy_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

homeboy_project_json() {
  local domain base_path server_id
  domain="$(homeboy_json_escape "$1")"
  base_path="$(homeboy_json_escape "$2")"
  server_id="$(homeboy_json_escape "${3:-}")"

  printf '{"domain":"%s","base_path":"%s"' "$domain" "$base_path"
  if [ -n "$server_id" ]; then
    printf ',"server_id":"%s"' "$server_id"
  fi
  printf '}'
}

homeboy_run() {
  if [ "${LOCAL_MODE:-false}" != true ] && \
     [ -n "${SERVICE_USER:-}" ] && \
     [ "$SERVICE_USER" != "root" ] && \
     [ -n "${SERVICE_HOME:-}" ] && \
     { [ "${WP_CODING_AGENTS_TEST_ASSUME_ROOT:-false}" = true ] || [ "$(id -u)" -eq 0 ]; } && \
     command -v sudo >/dev/null 2>&1; then
    sudo -n -H -u "$SERVICE_USER" env HOME="$SERVICE_HOME" PATH="$PATH" homeboy "$@"
    return $?
  fi

  homeboy "$@"
}

homeboy_server_json() {
  local user port
  user="$(homeboy_json_escape "$1")"
  port="$2"
  printf '{"host":"localhost","user":"%s","port":%s}' "$user" "$port"
}

homeboy_json_array() {
  local first=true value
  printf '['
  for value in "$@"; do
    if [ "$first" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$(homeboy_json_escape "$value")"
  done
  printf ']'
}

homeboy_dmc_wp_argv() {
  local argv=()
  if [ "${IS_STUDIO:-false}" = true ]; then
    argv=(studio wp)
  else
    # WP_CMD is intentionally a command string in setup profiles (e.g. "wp" or
    # "studio wp"). Split it the same way the existing wp_cmd helper invokes it.
    # shellcheck disable=SC2206
    argv=(${WP_CMD:-wp})
  fi

  printf '%s\n' "${argv[@]}"
}

homeboy_dmc_wp_flags() {
  local argv=()

  if [ -n "${SITE_PATH:-}" ]; then
    argv+=(--path="$SITE_PATH")
  fi

  # shellcheck disable=SC2206
  local root_flags=(${WP_ROOT_FLAG:-})
  argv+=("${root_flags[@]}")

  printf '%s\n' "${argv[@]}"
}

homeboy_dmc_command_json() {
  local action="$1"
  local wp_argv=()
  local wp_flags=()
  local value

  while IFS= read -r value; do
    wp_argv+=("$value")
  done < <(homeboy_dmc_wp_argv)

  while IFS= read -r value; do
    wp_flags+=("$value")
  done < <(homeboy_dmc_wp_flags)

  case "$action" in
    resolve_identity)
      homeboy_json_array php "$SCRIPT_DIR/scripts/homeboy-dmc-provider.php" identity "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" "$DM_WORKSPACE_DIR" '{handle}'
      ;;
    attest_safety)
      homeboy_json_array php "$SCRIPT_DIR/scripts/homeboy-dmc-provider.php" safety "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" "$DM_WORKSPACE_DIR" '{identity}'
      ;;
    resolve)
      homeboy_json_array php "$SCRIPT_DIR/scripts/homeboy-dmc-provider.php" resolve "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" "$DM_WORKSPACE_DIR" '{handle}'
      ;;
    resolve_path)
      homeboy_json_array php "$SCRIPT_DIR/scripts/homeboy-dmc-provider.php" resolve "$SITE_PATH/wp-content/plugins/data-machine-code/bin/dmc-worktree-provider" "$DM_WORKSPACE_DIR" '{path}'
      ;;
    ensure)
      # Homeboy owns each fanout worktree lifecycle. DMC verifies this complete
      # contract on creation and on owner-identical retries.
      homeboy_json_array "${wp_argv[@]}" datamachine-code workspace worktree add '{repo}' '{head}' '--from={base}' '--task-url={task_url}' '--reuse-policy=isolated' '--purpose={purpose}' '--owner-run-ref={owner_run_ref}' '--cleanup-policy={cleanup_policy}' --format=json "${wp_flags[@]}"
      ;;
    list)
      homeboy_json_array "${wp_argv[@]}" datamachine-code workspace worktree list --with-status --format=json "${wp_flags[@]}"
      ;;
    cleanup_preview)
      homeboy_json_array "${wp_argv[@]}" datamachine-code workspace cleanup safe --dry-run --format=json "${wp_flags[@]}"
      ;;
    cleanup_apply)
      homeboy_json_array "${wp_argv[@]}" datamachine-code workspace cleanup safe --format=json "${wp_flags[@]}"
      ;;
  esac
}

homeboy_dmc_worktree_provider_json() {
  printf '{"enabled":true,"kind":"command","apply_enabled":true,"lookup_timeout_ms":10000,"mutation_timeout_ms":120000,"commands":{"resolve_identity":%s,"attest_safety":%s,"resolve":%s,"resolve_path":%s,"resolve_not_found_exit_codes":[42],"ensure":%s,"list":%s,"cleanup_preview":%s,"cleanup_apply":%s},"list_result_mapping":{"items":"$","handle":"$.handle","path":"$.path","branch":"$.branch","dirty":"$.safety.dirty","unpushed":"$.safety.unpushed","primary":"$.safety.primary"}}' \
    "$(homeboy_dmc_command_json resolve_identity)" \
    "$(homeboy_dmc_command_json attest_safety)" \
    "$(homeboy_dmc_command_json resolve)" \
    "$(homeboy_dmc_command_json resolve_path)" \
    "$(homeboy_dmc_command_json ensure)" \
    "$(homeboy_dmc_command_json list)" \
    "$(homeboy_dmc_command_json cleanup_preview)" \
    "$(homeboy_dmc_command_json cleanup_apply)"
}

homeboy_project_id() {
  # 1. Explicit override.
  if [ -n "${HOMEBOY_PROJECT_ID:-}" ]; then
    printf '%s\n' "$HOMEBOY_PROJECT_ID"
    return 0
  fi

  # 2. Project config at the site root.
  if [ -n "${SITE_PATH:-}" ] && [ -f "$SITE_PATH/homeboy.json" ]; then
    local id
    id="$(python3 - "$SITE_PATH/homeboy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    project_id = json.load(handle).get("id", "")

if project_id:
    print(project_id)
PY
)"
    if [ -n "$id" ]; then
      printf '%s\n' "$id"
      return 0
    fi
    return 1
  fi

  # 3. Resolve from Homeboy's own registered projects by matching the project
  # domain to the WordPress site domain. This is the id that `homeboy project
  # show` / `attach-path` actually resolve from the site, so the resolver stays
  # consistent with what the attach loop targets — even with no homeboy.json at
  # the site root. Critically, this returns the REAL registered id (e.g.
  # "extrachill-site"), not a domain-slug guess.
  if [ -n "${SITE_DOMAIN:-}" ] && command -v homeboy >/dev/null 2>&1; then
    local project_list resolved
    project_list="$(homeboy_run project list 2>/dev/null)"
    if [ -n "$project_list" ]; then
      # Pass the JSON via env var (not stdin) so it does not collide with the
      # heredoc that supplies the python source on stdin.
      resolved="$(HOMEBOY_PROJECT_LIST="$project_list" HOMEBOY_SITE_DOMAIN="$SITE_DOMAIN" python3 <<'PY'
import json
import os

site_domain = os.environ.get("HOMEBOY_SITE_DOMAIN", "").strip().lower()

try:
    payload = json.loads(os.environ.get("HOMEBOY_PROJECT_LIST", ""))
except Exception:
    payload = {}

projects = payload.get("data", {}).get("projects", [])
for project in projects:
    domain = (project.get("domain") or "").strip().lower()
    if domain and domain == site_domain and project.get("id"):
        print(project["id"])
        break
PY
)"
      if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
        return 0
      fi

      # Local Studio installs can surface a transient localhost URL while the
      # registered Homeboy project keeps the stable Studio project id/domain.
      # In that case, resolve by base_path before falling back to a slug.
      if [ -n "${SITE_PATH:-}" ]; then
        resolved="$(HOMEBOY_PROJECT_LIST="$project_list" HOMEBOY_SITE_PATH="$SITE_PATH" python3 <<'PY'
import json
import os
from pathlib import Path

site_path = Path(os.environ.get("HOMEBOY_SITE_PATH", "")).expanduser()
try:
    site_path = site_path.resolve()
except Exception:
    site_path = site_path.absolute()

try:
    payload = json.loads(os.environ.get("HOMEBOY_PROJECT_LIST", ""))
except Exception:
    payload = {}

for project in payload.get("data", {}).get("projects", []):
    base_path = project.get("base_path") or ""
    if not base_path:
        continue
    candidate = Path(base_path).expanduser()
    try:
        candidate = candidate.resolve()
    except Exception:
        candidate = candidate.absolute()
    if candidate == site_path and project.get("id"):
        print(project["id"])
        break
PY
)"
        if [ -z "$resolved" ]; then
          local project_id project_ids project_json
          project_ids="$(HOMEBOY_PROJECT_LIST="$project_list" python3 <<'PY'
import json
import os

try:
    payload = json.loads(os.environ.get("HOMEBOY_PROJECT_LIST", ""))
except Exception:
    payload = {}

for project in payload.get("data", {}).get("projects", []):
    project_id = project.get("id") or ""
    if project_id:
        print(project_id)
PY
)"
          while IFS= read -r project_id; do
            [ -n "$project_id" ] || continue
            project_json="$(homeboy_run project show "$project_id" 2>/dev/null || true)"
            [ -n "$project_json" ] || continue
            resolved="$(HOMEBOY_PROJECT_JSON="$project_json" HOMEBOY_SITE_PATH="$SITE_PATH" python3 <<'PY'
import json
import os
from pathlib import Path

site_path = Path(os.environ.get("HOMEBOY_SITE_PATH", "")).expanduser()
try:
    site_path = site_path.resolve()
except Exception:
    site_path = site_path.absolute()

try:
    payload = json.loads(os.environ.get("HOMEBOY_PROJECT_JSON", ""))
except Exception:
    payload = {}

entity = payload.get("data", {}).get("entity", {})
base_path = entity.get("base_path") or ""
project_id = entity.get("id") or payload.get("data", {}).get("id") or ""
if base_path and project_id:
    candidate = Path(base_path).expanduser()
    try:
        candidate = candidate.resolve()
    except Exception:
        candidate = candidate.absolute()
    if candidate == site_path:
        print(project_id)
PY
)"
            if [ -n "$resolved" ]; then
              break
            fi
          done <<< "$project_ids"
        fi
        if [ -n "$resolved" ]; then
          printf '%s\n' "$resolved"
          return 0
        fi
      fi
    fi
  fi

  # 4. Last-ditch fallbacks for setup-time (project not yet registered): an
  # explicit agent slug, then a domain slug. These only ever produce an id to
  # CREATE a project with — they must never win over a real registered project
  # lookup above, which is why they run last.
  if [ -n "${AGENT_SLUG:-}" ]; then
    printf '%s\n' "$AGENT_SLUG"
    return 0
  fi

  if [ -n "${SITE_DOMAIN:-}" ]; then
    homeboy_slugify "$SITE_DOMAIN"
  elif [ -n "${SITE_PATH:-}" ]; then
    homeboy_slugify "$(basename "$SITE_PATH")"
  fi
}

homeboy_server_id() {
  if [ "$LOCAL_MODE" = true ]; then
    printf 'local'
    return 0
  fi

  if [ -n "${HOMEBOY_SERVER_ID:-}" ]; then
    printf '%s' "$HOMEBOY_SERVER_ID"
    return 0
  fi

  if [ "$DRY_RUN" = false ] && homeboy_run server show "$SITE_DOMAIN" >/dev/null 2>&1; then
    printf '%s' "$SITE_DOMAIN"
  fi

  return 0
}

ensure_homeboy_local_server() {
  if [ "$LOCAL_MODE" != true ]; then
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy server set local --json '{\"host\":\"localhost\",\"user\":\"$(whoami)\",\"port\":22}'"
    return 0
  fi

  if homeboy server show local >/dev/null 2>&1; then
    homeboy server set local --json "$(homeboy_server_json "$(whoami)" 22)" >/dev/null
  else
    homeboy server create local --host localhost --user "$(whoami)" --port 22 >/dev/null
  fi
}

homeboy_wordpress_extension_ready() {
  command -v homeboy >/dev/null 2>&1 || return 1

  local list_json
  list_json=$(homeboy_run extension list 2>/dev/null) || return 1

  printf '%s' "$list_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
extensions = data.get("data", {}).get("extensions", [])
for extension in extensions:
    if extension.get("id") == "wordpress":
        if extension.get("ready") is True and extension.get("compatible") is not False:
            sys.exit(0)
        sys.exit(1)
sys.exit(1)
' >/dev/null 2>&1
}

homeboy_wordpress_extension_linked() {
  command -v homeboy >/dev/null 2>&1 || return 1

  local show_json
  show_json=$(homeboy_run extension show wordpress 2>/dev/null) || return 1

  printf '%s' "$show_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("data", {}).get("extension", {}).get("linked") is True else 1)
' >/dev/null 2>&1
}

homeboy_required() {
  [ "${HOMEBOY_MODE:-auto}" = "enabled" ] || [ "${WITH_HOMEBOY:-false}" = true ]
}

homeboy_handle_failure() {
  local message="$1"
  if homeboy_required; then
    error "$message"
  fi
  warn "$message"
  return 0
}

sync_homeboy_agents_md_guidance() {
  # The Homeboy CLI command map is presence-gated on `command -v homeboy`.
  # Since #254 the section is registered as a LIVE-enumeration block: its
  # mu-plugin callback shells out to `homeboy --help` at AGENTS.md compose
  # time and parses the Commands: block in PHP (cached briefly on the binary
  # mtime + version). A `homeboy upgrade` therefore converges on the next
  # compose WITHOUT a wp-coding-agents sync — this function just keeps the
  # section block registered (or removes it when homeboy is absent, which
  # is itself the signal that homeboy is not callable on this host).
  if declare -F guidance_sync_unit >/dev/null; then
    guidance_sync_unit homeboy
  fi
}

setup_homeboy_project() {
  if [ "${HOMEBOY_MODE:-auto}" = "disabled" ]; then
    log "Skipping Homeboy project setup (--no-homeboy)"
    return 0
  fi

  if ! command -v homeboy >/dev/null 2>&1; then
    if homeboy_required; then
      error "Homeboy project setup requested, but the 'homeboy' command was not found"
    fi
    log "Skipping Homeboy project setup (homeboy not installed)"
    return 0
  fi

  local project_id server_id spec
  project_id="$(homeboy_project_id)"
  # Only cache a non-empty id. Caching an empty string here would otherwise
  # satisfy a later `[ -n "$HOMEBOY_PROJECT_ID" ]` check is false, but more
  # importantly it must never shadow the resolver's homeboy.json / registered-
  # project fallbacks with a blank value.
  if [ -n "$project_id" ]; then
    HOMEBOY_PROJECT_ID="$project_id"
  fi
  server_id="$(homeboy_server_id)"
  HOMEBOY_SERVER_ID_RESOLVED="$server_id"
  spec="$(homeboy_project_json "$SITE_DOMAIN" "$SITE_PATH" "$server_id")"

  log "Phase 4.6: Creating/updating Homeboy project '$project_id' for WordPress site"
  log "Homeboy project target: domain=$SITE_DOMAIN path=$SITE_PATH${server_id:+ server=$server_id}"

  ensure_homeboy_local_server

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy project set $project_id --json '$spec' || homeboy project create $project_id $SITE_DOMAIN --base-path '$SITE_PATH'${server_id:+ --server-id $server_id}"
    return 0
  fi

  if homeboy project show "$project_id" >/dev/null 2>&1; then
    homeboy project set "$project_id" --json "$spec" >/dev/null
    log "Updated Homeboy project '$project_id'"
  else
    if [ -n "$server_id" ]; then
      homeboy project create "$project_id" "$SITE_DOMAIN" --base-path "$SITE_PATH" --server-id "$server_id" >/dev/null
    else
      homeboy project create "$project_id" "$SITE_DOMAIN" --base-path "$SITE_PATH" >/dev/null
    fi
    log "Created Homeboy project '$project_id'"
  fi
}

configure_homeboy_dmc_worktree_provider() {
  if [ "${HOMEBOY_MODE:-auto}" = "disabled" ]; then
    log "Skipping Homeboy DMC worktree provider setup (--no-homeboy)"
    return 0
  fi

  if ! command -v homeboy >/dev/null 2>&1; then
    homeboy_handle_failure "Homeboy is not callable from this setup/runtime PATH; skipping DMC worktree provider setup."
    return 0
  fi

  local provider_json
  provider_json="$(homeboy_dmc_worktree_provider_json)"

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy config set /worktree_providers/dmc '$provider_json'"
    return 0
  fi

  if [ -n "${SITE_PATH:-}" ] && { [ -f "$SITE_PATH/wp-config.php" ] || [ -f "$SITE_PATH/wp-load.php" ]; }; then
    if ! wp_cmd datamachine-code workspace worktree list --format=json >/dev/null 2>&1; then
      homeboy_handle_failure "Data Machine Code WP-CLI commands are not available; skipping Homeboy DMC worktree provider setup."
      return 0
    fi
  fi

  log "Configuring Homeboy DMC worktree provider."
  homeboy_run config set /worktree_providers/dmc "$provider_json" >/dev/null || \
    homeboy_handle_failure "Homeboy DMC worktree provider config failed."
}

configure_homeboy_wordpress_extension() {
  HOMEBOY_WORDPRESS_READY=false

  if [ "${HOMEBOY_MODE:-auto}" = "disabled" ]; then
    sync_homeboy_availability
    sync_homeboy_agents_md_guidance
    recompose_agents_md_for_homeboy
    return 0
  fi

  if ! command -v homeboy >/dev/null 2>&1; then
    homeboy_handle_failure "Homeboy is not callable from this setup/runtime PATH; skipping Homeboy WordPress extension setup."
    sync_homeboy_availability
    sync_homeboy_agents_md_guidance
    recompose_agents_md_for_homeboy
    return 0
  fi

  log "Detected Homeboy: $(command -v homeboy)"

  if ! homeboy_required; then
    if homeboy_wordpress_extension_ready; then
      HOMEBOY_WORDPRESS_READY=true
      log "Homeboy WordPress extension is installed and ready."
    else
      warn "Homeboy is callable, but the WordPress extension is not ready. Run setup with --with-homeboy to install and verify it."
    fi
    sync_homeboy_availability
    sync_homeboy_agents_md_guidance
    recompose_agents_md_for_homeboy
    return 0
  fi

  local source="${HOMEBOY_EXTENSIONS_SOURCE:-$HOMEBOY_EXTENSIONS_SOURCE_DEFAULT}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy extension install $source --id wordpress"
    echo -e "${BLUE}[dry-run]${NC} homeboy extension update wordpress  # if already installed and not linked"
    echo -e "${BLUE}[dry-run]${NC} homeboy extension setup wordpress"
    echo -e "${BLUE}[dry-run]${NC} homeboy extension list"
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update datamachine_code_homeboy_available 1"
    echo -e "${BLUE}[dry-run]${NC} Would sync Homeboy AGENTS.md CLI guidance mu-plugin"
    print_homeboy_verification_commands
    return 0
  fi

  if homeboy extension show wordpress >/dev/null 2>&1; then
    if homeboy_wordpress_extension_linked; then
      log "Homeboy WordPress extension is linked locally — skipping git update."
    else
      log "Updating Homeboy WordPress extension..."
      homeboy extension update wordpress >/dev/null || homeboy_handle_failure "Homeboy WordPress extension update failed."
    fi
  else
    log "Installing Homeboy WordPress extension from $source..."
    homeboy extension install "$source" --id wordpress >/dev/null || homeboy_handle_failure "Homeboy WordPress extension install failed from $source."
  fi

  log "Running Homeboy WordPress extension setup..."
  homeboy extension setup wordpress >/dev/null || homeboy_handle_failure "Homeboy WordPress extension setup failed."

  if homeboy_wordpress_extension_ready; then
    HOMEBOY_WORDPRESS_READY=true
    log "Homeboy WordPress extension is ready."
  else
    homeboy_handle_failure "Homeboy WordPress extension did not pass readiness verification."
  fi

  sync_homeboy_availability
  sync_homeboy_agents_md_guidance
  recompose_agents_md_for_homeboy
  print_homeboy_verification_commands
}

recompose_agents_md_for_homeboy() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} (as ${SERVICE_USER:-caller}) $WP_CMD datamachine memory compose AGENTS.md"
    return 0
  fi

  if [ ! -f "$SITE_PATH/wp-config.php" ] && [ ! -f "$SITE_PATH/wp-load.php" ]; then
    return 0
  fi

  # As the service user — see wp_run_as_service_user(). A recompose that runs as
  # root re-bakes `wp --allow-root` into the examples and would silently undo the
  # correct file the main compose phase just wrote.
  if (cd "$SITE_PATH" && wp_run_as_service_user datamachine memory compose AGENTS.md >/dev/null 2>&1); then
    log "AGENTS.md recomposed after Homeboy availability sync."
    opencode_project_subagents
  else
    homeboy_handle_failure "Could not recompose AGENTS.md after Homeboy availability sync."
  fi
}

print_homeboy_verification_commands() {
  log "Homeboy verification commands:"
  echo "  homeboy extension list"
  echo "  homeboy extension show wordpress"
  echo "  homeboy project show <project-id>"
  echo "  homeboy project components list <project-id>"
  echo "  ./scripts/verify-homeboy-codebox-canary.sh --workspace <repo-or-worktree> --secret-env <ENV_NAME> --agents-api <path> --agent-runtime <path> --agent-runtime-tools <path> --provider-plugin-path <path>  # opt-in model-backed Codebox canary; use --provider claude-code and the carried ai-provider-for-claude-code path for Claude Code; add --run to execute"
}
