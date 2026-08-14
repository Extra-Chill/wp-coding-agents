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
  [ -f "$SITE_PATH/wp-config.php" ] || return 0
  [ -f "$SITE_PATH/opencode.json" ] || return 0

  local graph_helper projector agent_json
  graph_helper="$SCRIPT_DIR/lib/read-opencode-subagent-graph.php"
  projector="$SCRIPT_DIR/lib/project-opencode-subagents.py"
  [ -f "$graph_helper" ] || { warn "OpenCode subagent graph reader not found: $graph_helper"; return 1; }
  [ -f "$projector" ] || { warn "OpenCode subagent projector not found: $projector"; return 1; }

  # The Agents API registry owns child topology. Data Machine owns the
  # registered identity files and declared skill artifacts used by the reader.
  agent_json="$(wp_cmd eval-file "$graph_helper" -- "$AGENT_SLUG" 2>/dev/null)" || {
    warn "Could not read the Agents API subagent graph for coordinator '$AGENT_SLUG'"
    return 1
  }
  local source
  source="$(mktemp)"
  printf '%s' "$agent_json" > "$source"
  local before after
  before="$(tar -cf - -C "$SITE_PATH" opencode.json .opencode 2>/dev/null | shasum || true)"
  if ! python3 "$projector" "$source" "$SITE_PATH"; then
    rm -f "$source"
    return 1
  fi
  rm -f "$source"
  after="$(tar -cf - -C "$SITE_PATH" opencode.json .opencode 2>/dev/null | shasum || true)"
  if [ "$before" != "$after" ]; then
    if [ -n "${UPDATED_ITEMS+x}" ]; then
      UPDATED_ITEMS+=("OpenCode subagent graph (restart OpenCode to load changes)")
    fi
    warn "OpenCode subagent graph changed. Restart OpenCode; it does not hot-reload agent files or task permissions."
  fi
}
