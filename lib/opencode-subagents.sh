#!/bin/bash
# Project Data Machine's persisted portable agent graph for OpenCode.

opencode_external_graph_eval() {
  local reader_code="$1"
  local timeout_seconds="${OPENCODE_EXTERNAL_GRAPH_TIMEOUT_SECONDS:-120}"
  local response_file pid elapsed status attempt
  case "$timeout_seconds" in
    ''|*[!0-9]*) timeout_seconds=120 ;;
  esac
  [ "$timeout_seconds" -gt 0 ] || timeout_seconds=120
  response_file="$(mktemp)" || return 1
  for attempt in 1 2 3; do
    : > "$response_file"
    wp_cmd eval "$reader_code" > "$response_file" 2>/dev/null &
    pid=$!
    elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$elapsed" -ge "$timeout_seconds" ]; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        break
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    if wait "$pid" 2>/dev/null; then status=0; else status=$?; fi
    if [ "$status" -eq 0 ]; then
      cat "$response_file"
      rm -f "$response_file"
      return 0
    fi
  done
  rm -f "$response_file"
  return 1
}

opencode_project_subagents() {
  OPENCODE_SUBAGENT_PROJECTION_FAILURE=''
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
  [ -f "$graph_helper" ] || { OPENCODE_SUBAGENT_PROJECTION_FAILURE=missing_reader; warn "OpenCode subagent graph reader not found: $graph_helper"; return 1; }
  [ -f "$projector" ] || { OPENCODE_SUBAGENT_PROJECTION_FAILURE=missing_projector; warn "OpenCode subagent projector not found: $projector"; return 1; }

  # The Agents API registry owns child topology. Data Machine owns the
  # registered identity files and declared skill artifacts used by the reader.
  # External hosts only receive wp eval, so transfer this local reader as one
  # argv-safe PHP expression and request a self-contained graph.
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    local reader_code reader_payload slug_payload
    local chunk_size=1024 offset=0 expected_size='' response reported_size encoded_chunk encoded_chunks=''
    reader_payload="$(base64 < "$graph_helper" | tr -d '\n')"
    slug_payload="$(printf '%s' "$AGENT_SLUG" | base64 | tr -d '\n')"
    while [ -z "$expected_size" ] || [ "$offset" -lt "$expected_size" ]; do
      reader_code="ob_start();\$args=array(base64_decode('$slug_payload'),'embedded');eval('?>'.base64_decode('$reader_payload'));\$graph=ob_get_clean();echo json_encode(array('size'=>strlen(\$graph),'chunk'=>base64_encode(substr(\$graph,$offset,$chunk_size))));"
      response="$(opencode_external_graph_eval "$reader_code")" || {
        OPENCODE_SUBAGENT_PROJECTION_FAILURE=wp_cli_read
        warn "Could not read the Agents API subagent graph for coordinator '$AGENT_SLUG'"
        return 1
      }
      IFS=$'\t' read -r reported_size encoded_chunk < <(printf '%s' "$response" | python3 -c '
import json, sys
value = json.load(sys.stdin)
size, chunk = value.get("size"), value.get("chunk")
if not isinstance(size, int) or size < 0 or size > 4 * 1024 * 1024 or not isinstance(chunk, str):
    raise SystemExit(1)
print(f"{size}\t{chunk}")
') || {
        OPENCODE_SUBAGENT_PROJECTION_FAILURE=invalid_transport_response
        warn "External subagent graph returned an invalid chunk"
        return 1
      }
      if [ -z "$expected_size" ]; then
        expected_size="$reported_size"
      elif [ "$reported_size" != "$expected_size" ]; then
        OPENCODE_SUBAGENT_PROJECTION_FAILURE=unstable_transport_response
        warn "External subagent graph changed during chunked transfer"
        return 1
      fi
      encoded_chunks+="$encoded_chunk"$'\n'
      offset=$((offset + chunk_size))
    done
    agent_json="$(printf '%s' "$encoded_chunks" | python3 -c '
import base64, sys
expected = int(sys.argv[1])
value = b"".join(base64.b64decode(line, validate=True) for line in sys.stdin.buffer.read().splitlines())
if len(value) != expected:
    raise SystemExit(1)
sys.stdout.buffer.write(value)
' "$expected_size")" || {
      OPENCODE_SUBAGENT_PROJECTION_FAILURE=incomplete_transport_response
      warn "External subagent graph transfer was incomplete"
      return 1
    }
  else
    local reader_code reader_payload slug_payload reader_error
    reader_payload="$(base64 < "$graph_helper" | tr -d '\n')"
    slug_payload="$(printf '%s' "$AGENT_SLUG" | base64 | tr -d '\n')"
    reader_code="\$args=array(base64_decode('$slug_payload'),'embedded');eval('?>'.base64_decode('$reader_payload'));"
    reader_error="$(mktemp)" || { OPENCODE_SUBAGENT_PROJECTION_FAILURE=temporary_file; warn "Could not prepare OpenCode subagent graph diagnostics"; return 1; }
    agent_json="$(wp_cmd eval "$reader_code" 2>"$reader_error")" || {
      cat "$reader_error" >&2
      if grep -Fq 'The coordinator is not a registered Agents API agent.' "$reader_error"; then
        OPENCODE_SUBAGENT_PROJECTION_FAILURE=unregistered_coordinator
        warn "Configured Data Machine agent '$AGENT_SLUG' is not a registered Agents API coordinator"
      else
        OPENCODE_SUBAGENT_PROJECTION_FAILURE=wp_cli_read
        warn "Could not read the Agents API subagent graph for coordinator '$AGENT_SLUG'; inspect the WP-CLI error above"
      fi
      rm -f "$reader_error"
      return 1
    }
    rm -f "$reader_error"
  fi
  local source
  local before after
  before="$(tar -cf - -C "$SITE_PATH" opencode.json .opencode 2>/dev/null | shasum || true)"
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    if ! printf '%s' "$agent_json" | python3 "$projector" --stdin "$SITE_PATH"; then
      OPENCODE_SUBAGENT_PROJECTION_FAILURE=projector
      return 1
    fi
  else
    source="$(mktemp)"
    printf '%s' "$agent_json" > "$source"
    if ! python3 "$projector" "$source" "$SITE_PATH"; then
      rm -f "$source"
      OPENCODE_SUBAGENT_PROJECTION_FAILURE=projector
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

# Subagent projection augments an already-valid OpenCode runtime. A missing
# Agents API coordinator must not discard an upgrade summary after earlier
# phases have applied their changes.
opencode_project_subagents_optional() {
  if opencode_project_subagents; then
    return 0
  fi

  if [ "${OPENCODE_SUBAGENT_PROJECTION_FAILURE:-}" = unregistered_coordinator ]; then
    warn "OpenCode subagent projection is pending; register the configured Data Machine agent as an Agents API coordinator, then re-run setup or upgrade."
    if declare -p PENDING_ITEMS >/dev/null 2>&1; then
      PENDING_ITEMS+=("OpenCode subagent projection (configured coordinator is not registered)")
    fi
    return 0
  fi

  warn "OpenCode subagent projection failed (${OPENCODE_SUBAGENT_PROJECTION_FAILURE:-unknown}); correct the reported failure before retrying."
  return 1
}
