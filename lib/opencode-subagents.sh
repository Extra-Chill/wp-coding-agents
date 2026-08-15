#!/bin/bash
# Project Data Machine's persisted portable agent graph for OpenCode.

opencode_project_subagents() {
  [ "${DRY_RUN:-false}" = true ] && return 0
  local runtime has_opencode=false
  for runtime in "${DETECTED_RUNTIMES[@]:-}"; do
    [ "$runtime" = opencode ] && has_opencode=true
  done
  [ "$has_opencode" = true ] || [ "${RUNTIME:-}" = opencode ] || return 0
  [ -n "${AGENT_SLUG:-}" ] || return 0
  [ -f "$SITE_PATH/wp-config.php" ] || [ "${EXTERNAL_WORDPRESS:-false}" = true ] || return 0
  [ -f "$SITE_PATH/opencode.json" ] || return 0

  local graph_helper projector agent_json
  graph_helper="$SCRIPT_DIR/lib/read-opencode-subagent-graph.php"
  projector="$SCRIPT_DIR/lib/project-opencode-subagents.py"
  [ -f "$graph_helper" ] || { warn "OpenCode subagent graph reader not found: $graph_helper"; return 1; }
  [ -f "$projector" ] || { warn "OpenCode subagent projector not found: $projector"; return 1; }

  # The Agents API registry owns child topology. Data Machine owns the
  # registered identity files and declared skill artifacts used by the reader.
  # External hosts only receive wp eval, so transfer this local reader as one
  # argv-safe PHP expression and request a self-contained graph.
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    local reader_code reader_payload slug_payload
    reader_payload="$(base64 < "$graph_helper" | tr -d '\n')"
    slug_payload="$(printf '%s' "$AGENT_SLUG" | base64 | tr -d '\n')"
    reader_code="\$args=array(base64_decode('$slug_payload'),'embedded');eval('?>'.base64_decode('$reader_payload'));"
    agent_json="$(wp_cmd eval "$reader_code" 2>/dev/null)" || {
      warn "Could not read the Agents API subagent graph for coordinator '$AGENT_SLUG'"
      return 1
    }
  else
    agent_json="$(wp_cmd eval-file "$graph_helper" -- "$AGENT_SLUG" 2>/dev/null)" || {
      warn "Could not read the Agents API subagent graph for coordinator '$AGENT_SLUG'"
      return 1
    }
  fi
  local source
  local before after
  before="$(tar -cf - -C "$SITE_PATH" opencode.json .opencode 2>/dev/null | shasum || true)"
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    printf '%s' "$agent_json" | python3 "$projector" --stdin "$SITE_PATH" || return 1
  else
    source="$(mktemp)"
    printf '%s' "$agent_json" > "$source"
    if ! python3 "$projector" "$source" "$SITE_PATH"; then
      rm -f "$source"
      return 1
    fi
    rm -f "$source"
  fi
  after="$(tar -cf - -C "$SITE_PATH" opencode.json .opencode 2>/dev/null | shasum || true)"
  if [ "$before" != "$after" ]; then
    if [ -n "${UPDATED_ITEMS+x}" ]; then
      UPDATED_ITEMS+=("OpenCode subagent graph (restart OpenCode to load changes)")
    fi
    warn "OpenCode subagent graph changed. Restart OpenCode; it does not hot-reload agent files or task permissions."
  fi
}
