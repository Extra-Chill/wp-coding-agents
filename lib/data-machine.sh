#!/bin/bash
# Data Machine: plugin installation, agent creation, SOUL/MEMORY scaffold

install_data_machine() {
  log "Phase 4: Installing Data Machine..."
  install_plugin data-machine https://github.com/Extra-Chill/data-machine.git

  if [ "$MULTISITE" = true ]; then
    log "Data Machine activated on main site. Activate on subsites with:"
    log "  $WP_CMD plugin activate data-machine --url=subsite.$SITE_DOMAIN $WP_ROOT_FLAG"
  fi

  # Data Machine Code is the workspace/git/GitHub tool surface. A managed
  # install has no workspace by design — the agent edits live source and
  # changes are captured out-of-band — so installing DMC there contributes
  # ~90 abilities the agent cannot use plus an AGENTS.md section instructing
  # it to route work through a git workflow it has no access to. AGENTS.md
  # composition is unaffected: data-machine core registers the composable file
  # itself behind the same DATAMACHINE_COMPOSE_AGENTS_MD gate.
  if source_policy_workspace_enabled; then
    log "Installing Data Machine Code (developer tools)..."
    install_plugin data-machine-code https://github.com/Extra-Chill/data-machine-code.git

    # Set workspace path in wp-config.php if not already defined
    if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ] && [ "$IS_STUDIO" = false ]; then
      if ! grep -q 'DATAMACHINE_WORKSPACE_PATH' "$SITE_PATH/wp-config.php"; then
        wp_cmd config set DATAMACHINE_WORKSPACE_PATH "$DM_WORKSPACE_DIR" --type=constant
        log "Set DATAMACHINE_WORKSPACE_PATH to $DM_WORKSPACE_DIR"
      else
        log "DATAMACHINE_WORKSPACE_PATH already defined in wp-config.php"
      fi
    elif [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} $WP_CMD config set DATAMACHINE_WORKSPACE_PATH $DM_WORKSPACE_DIR --type=constant"
    fi
  else
    log "Skipping Data Machine Code (source mode: ${SOURCE_MODE:-owned} — no workspace on this install)"
  fi

  set_compose_agents_md_constant
}

# Write the DATAMACHINE_COMPOSE_AGENTS_MD gate to wp-config.php.
#
# This boolean constant turns ON core-owned AGENTS.md composition in Data
# Machine (see data-machine#2640). wp-coding-agents is the rightful writer
# because its presence is the signal that an external coding agent lives here —
# installs without one stay default-OFF and emit zero AGENTS.md noise.
#
# Mirrors the DATAMACHINE_WORKSPACE_PATH block above: idempotent grep-guard,
# respects DRY_RUN / IS_STUDIO / wp-config.php existence. Written as a raw
# boolean (true) via --raw so the define is `define( ..., true )`, not the
# string "true". Safe to (re-)run on both setup and upgrade; harmless even if
# core does not yet read the constant.
set_compose_agents_md_constant() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ] && [ "$IS_STUDIO" = false ]; then
    if ! grep -q 'DATAMACHINE_COMPOSE_AGENTS_MD' "$SITE_PATH/wp-config.php"; then
      wp_cmd config set DATAMACHINE_COMPOSE_AGENTS_MD true --raw --type=constant
      log "Set DATAMACHINE_COMPOSE_AGENTS_MD to true"
    else
      log "DATAMACHINE_COMPOSE_AGENTS_MD already defined in wp-config.php"
    fi
  elif [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $WP_CMD config set DATAMACHINE_COMPOSE_AGENTS_MD true --raw --type=constant"
  fi
}

upgrade_data_machine_plugins() {
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    log "Phase 2: Skipping Data Machine plugins (--no-data-machine)"
    return
  fi

  log "Phase 2: Updating Data Machine plugins to latest tagged releases..."
  update_plugin_to_latest_tag data-machine https://github.com/Extra-Chill/data-machine.git

  # Managed installs deliberately have no DMC. Without this gate every upgrade
  # silently reinstalls and reactivates it, because update_plugin_to_latest_tag
  # activates — which is exactly why hand-deactivating DMC never stuck.
  if source_policy_workspace_enabled; then
    update_plugin_to_latest_tag data-machine-code https://github.com/Extra-Chill/data-machine-code.git
  else
    log "  Skipping Data Machine Code (source mode: ${SOURCE_MODE:-owned})"
  fi

  # Backfill the AGENTS.md composition gate on existing installs (idempotent).
  set_compose_agents_md_constant
}

# Derive a Data Machine agent slug from a site domain. Shared by setup
# (create_dm_agent) and upgrade (claude-code runtime sync) so both compute the
# same canonical slug: first domain label, lowercased, underscores → hyphens.
derive_agent_slug() {
  echo "$1" | sed 's/\..*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

create_dm_agent() {
  log "Phase 4.5: Creating Data Machine agent..."

  # Derive agent slug from domain
  if [ -z "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG=$(derive_agent_slug "$SITE_DOMAIN")
  fi

  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    # shellcheck disable=SC2086
    AGENT_NAME="${AGENT_NAME:-$($WP_CMD option get blogname $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || echo "$AGENT_SLUG")}"

    # Check if agent already exists (idempotent for re-runs)
    # shellcheck disable=SC2086
    EXISTING_AGENT=$($WP_CMD datamachine agents show "$AGENT_SLUG" --format=json $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null || echo "")

    if [ -z "$EXISTING_AGENT" ]; then
      log "Creating agent: $AGENT_SLUG ($AGENT_NAME)"
      wp_cmd datamachine agents create "$AGENT_SLUG" \
        --name="$AGENT_NAME" \
        --owner=1

      log "Agent '$AGENT_SLUG' created. SOUL.md and MEMORY.md seeded by Data Machine with sensible defaults — customize via 'wp datamachine memory write' or by editing the files directly."
    else
      log "Agent '$AGENT_SLUG' already exists — skipping creation"
    fi
  else
    log "Dry-run: would create agent '$AGENT_SLUG' with SOUL.md and MEMORY.md"
  fi
}

sync_homeboy_availability() {
  if [ "$DRY_RUN" = true ]; then
    if [ "${HOMEBOY_WORDPRESS_READY:-false}" = true ] || homeboy_wordpress_extension_ready; then
      echo -e "${BLUE}[dry-run]${NC} $WP_CMD option update datamachine_code_homeboy_available 1"
    else
      echo -e "${BLUE}[dry-run]${NC} $WP_CMD option delete datamachine_code_homeboy_available"
    fi
    sync_homeboy_project_components
    return 0
  fi

  if [ "${HOMEBOY_WORDPRESS_READY:-false}" = true ] || homeboy_wordpress_extension_ready; then
    wp_cmd option update datamachine_code_homeboy_available 1 >/dev/null 2>&1 || \
      warn "Could not record Homeboy availability for AGENTS.md compose"
    sync_homeboy_project_components
  else
    wp_cmd option delete datamachine_code_homeboy_available >/dev/null 2>&1 || true
  fi
}

discover_dm_workspace_dir() {
  if [ -n "${DATAMACHINE_WORKSPACE_PATH:-}" ]; then
    DM_WORKSPACE_DIR="$DATAMACHINE_WORKSPACE_PATH"
    return 0
  fi

  if [ "${DRY_RUN:-false}" = true ] || [ -z "${SITE_PATH:-}" ] || [ ! -f "$SITE_PATH/wp-config.php" ]; then
    return 0
  fi

  local workspace_path
  workspace_path=$(wp_cmd datamachine-code workspace path 2>/dev/null || true)
  if [ -n "$workspace_path" ]; then
    DM_WORKSPACE_DIR="$workspace_path"
  fi
}

# NOTE: homeboy_project_id() is defined once, in lib/homeboy.sh, which is
# sourced after this file. A duplicate definition used to live here and was
# silently shadowed by the homeboy.sh copy (see #170) — keep it single-sourced.

sync_homeboy_project_components() {
  if ! command -v homeboy >/dev/null 2>&1; then
    return 0
  fi

  discover_dm_workspace_dir

  local project_id
  if ! project_id=$(homeboy_project_id); then
    warn "Homeboy project config not found at site root — skipping DMC component attachment"
    return 0
  fi

  if [ -z "$project_id" ]; then
    warn "Homeboy project config returned empty id — skipping DMC component attachment"
    return 0
  fi

  if [ -z "${DM_WORKSPACE_DIR:-}" ]; then
    warn "DMC workspace path not configured — skipping Homeboy component attachment"
    return 0
  fi

  if [ ! -d "$DM_WORKSPACE_DIR" ]; then
    warn "DMC workspace path does not exist ($DM_WORKSPACE_DIR) — skipping Homeboy component attachment"
    return 0
  fi

  log "Attaching Homeboy components from DMC workspace: $DM_WORKSPACE_DIR"

  prune_homeboy_project_components "$project_id"

  local attached=0
  local skipped=0
  local failed=0
  local repo_path repo_name

  shopt -s nullglob
  for repo_path in "$DM_WORKSPACE_DIR"/*; do
    [ -d "$repo_path" ] || continue
    repo_name=$(basename "$repo_path")

    if [ -n "${SITE_PATH:-}" ] && [ "$repo_path" = "$SITE_PATH" ]; then
      log "  skipped $repo_name: site project root"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$repo_name" == *"@"* ]]; then
      log "  skipped $repo_name: worktree skipped"
      skipped=$((skipped + 1))
      continue
    fi

    if [ ! -f "$repo_path/homeboy.json" ]; then
      log "  skipped $repo_name: no homeboy.json"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} homeboy project components attach-path $project_id $repo_path"
      attached=$((attached + 1))
      continue
    fi

    local attach_output attach_status
    set +e
    attach_output="$(homeboy_run project components attach-path "$project_id" "$repo_path" 2>&1)"
    attach_status=$?
    set -e

    # Trust Homeboy's JSON `.success` field over the raw exit code: the CLI
    # can print a success payload while still returning a non-zero status (or
    # vice versa). Fall back to the exit code only when the output is not
    # parseable JSON.
    if homeboy_attach_succeeded "$attach_output" "$attach_status"; then
      log "  attached $repo_name"
      attached=$((attached + 1))
    else
      warn "  failed $repo_name: homeboy attach-path failed"
      if [ -n "$attach_output" ]; then
        warn "    $(printf '%s' "$attach_output" | head -n 3 | tr '\n' ' ')"
      fi
      failed=$((failed + 1))
    fi
  done
  shopt -u nullglob

  log "Homeboy component sync complete: $attached attached, $skipped skipped, $failed failed"
}

prune_homeboy_project_components() {
  local project_id="$1"

  [ -n "$project_id" ] || return 0
  [ -n "${DM_WORKSPACE_DIR:-}" ] || return 0

  local project_json
  project_json="$(homeboy_run project show "$project_id" 2>/dev/null || true)"
  [ -n "$project_json" ] || return 0

  local component_ids
  component_ids="$(HOMEBOY_PROJECT_JSON="$project_json" HOMEBOY_DM_WORKSPACE_DIR="$DM_WORKSPACE_DIR" python3 <<'PY'
import json
import os
from pathlib import Path

try:
    payload = json.loads(os.environ.get("HOMEBOY_PROJECT_JSON", ""))
except Exception:
    raise SystemExit(0)

workspace = Path(os.environ.get("HOMEBOY_DM_WORKSPACE_DIR", "")).resolve()
components = payload.get("data", {}).get("entity", {}).get("components", [])
for component in components:
    component_id = component.get("id") or ""
    local_path = component.get("local_path") or ""
    if not component_id or not local_path:
        continue

    path = Path(local_path).expanduser()
    try:
        resolved = path.resolve()
    except Exception:
        resolved = path.absolute()

    try:
        resolved.relative_to(workspace)
    except ValueError:
        continue

    if "@" in path.name or not (resolved / "homeboy.json").is_file():
        print(component_id)
PY
)"

  [ -n "$component_ids" ] || return 0

  local remove_ids=()
  local component_id
  while IFS= read -r component_id; do
    [ -n "$component_id" ] || continue
    remove_ids+=("$component_id")
  done <<< "$component_ids"

  [ ${#remove_ids[@]} -gt 0 ] || return 0

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} homeboy project components remove $project_id ${remove_ids[*]}"
    return 0
  fi

  local remove_output remove_status
  set +e
  remove_output="$(homeboy_run project components remove "$project_id" "${remove_ids[@]}" 2>&1)"
  remove_status=$?
  set -e

  if homeboy_attach_succeeded "$remove_output" "$remove_status" || homeboy_components_absent "$project_id" "${remove_ids[@]}"; then
    log "  pruned stale Homeboy component(s): ${remove_ids[*]}"
  else
    warn "  failed to prune stale Homeboy component(s): ${remove_ids[*]}"
    if [ -n "$remove_output" ]; then
      warn "    $(printf '%s' "$remove_output" | head -n 3 | tr '\n' ' ')"
    fi
  fi
}

homeboy_components_absent() {
  local project_id="$1"
  shift
  [ -n "$project_id" ] || return 1
  [ "$#" -gt 0 ] || return 0

  local project_json
  project_json="$(homeboy_run project show "$project_id" 2>/dev/null || true)"
  [ -n "$project_json" ] || return 1

  local remaining
  remaining="$(HOMEBOY_PROJECT_JSON="$project_json" python3 - "$@" <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("HOMEBOY_PROJECT_JSON", ""))
except Exception:
    raise SystemExit(1)

expected_absent = set(sys.argv[1:])
components = payload.get("data", {}).get("entity", {}).get("components", [])
present = {
    component.get("id")
    for component in components
    if component.get("id")
}
for component_id in sorted(expected_absent & present):
    print(component_id)
PY
)"

  [ -z "$remaining" ]
}

# Decide whether a `homeboy ... attach-path` invocation succeeded. Prefers the
# JSON `.success` field in the command output; falls back to the process exit
# status when the output is not JSON (e.g. an early crash before any payload).
homeboy_attach_succeeded() {
  local output="$1"
  local status="$2"

  local verdict
  # Pass the command output via env var (not stdin) so it does not collide
  # with the heredoc that supplies the python source on stdin.
  verdict="$(HOMEBOY_ATTACH_OUTPUT="$output" python3 <<'PY' 2>/dev/null
import json
import os

raw = os.environ.get("HOMEBOY_ATTACH_OUTPUT", "").strip()
if not raw:
    print("nojson")
    raise SystemExit(0)

# Output may include leading log lines before the JSON object; isolate the
# outermost JSON object if present.
start = raw.find("{")
end = raw.rfind("}")
if start == -1 or end == -1 or end < start:
    print("nojson")
    raise SystemExit(0)

try:
    payload = json.loads(raw[start : end + 1])
except Exception:
    print("nojson")
    raise SystemExit(0)

print("ok" if payload.get("success") is True else "fail")
PY
)"

  case "$verdict" in
    ok)   return 0 ;;
    fail) return 1 ;;
    *)    [ "$status" -eq 0 ] ;;  # nojson / unknown -> trust exit code
  esac
}
