#!/bin/bash
# External WordPress control transport for runtimes that do not mount the site.

runtime_project_root() {
  printf '%s' "${RUNTIME_PROJECT_ROOT:-$SITE_PATH}"
}

external_wordpress_control_command() {
  printf '%s' "$(runtime_project_root)/.wp-coding-agents/bin/wp-control"
}

external_wordpress_kimaki_command() {
  printf '%s' "$(runtime_project_root)/.wp-coding-agents/bin/kimaki"
}

external_wordpress_kimaki_credential_command() {
  printf '%s' "$(runtime_project_root)/.wp-coding-agents/bin/kimaki-seed-credential"
}

external_wordpress_prepare_transport() {
  [ "${EXTERNAL_WORDPRESS:-false}" = true ] || return 0
  [ -n "${RUNTIME_PROJECT_ROOT:-}" ] || error "--external-wordpress requires --runtime-project-root or RUNTIME_PROJECT_ROOT"
  [ -n "${WORDPRESS_PATH:-}" ] || error "--external-wordpress requires --wordpress-path or WORDPRESS_PATH"
  [ -n "${WP_CONTROL_TRANSPORT_JSON:-}" ] || error "--external-wordpress requires WP_CONTROL_TRANSPORT_JSON, a JSON argv array"
  python3 - "$WP_CONTROL_TRANSPORT_JSON" <<'PY' || error "WP_CONTROL_TRANSPORT_JSON must be a non-empty JSON array of non-empty strings without NUL bytes"
import json, sys
value = json.loads(sys.argv[1])
if not isinstance(value, list) or not value or any(not isinstance(item, str) or not item or "\0" in item for item in value):
    raise SystemExit(1)
PY
  WP_CONTROL_TRANSPORT=()
  while IFS= read -r -d '' transport_argument; do
    WP_CONTROL_TRANSPORT+=("$transport_argument")
  done < <(python3 - "$WP_CONTROL_TRANSPORT_JSON" <<'PY'
import json, sys
for item in json.loads(sys.argv[1]):
    sys.stdout.buffer.write(item.encode() + b"\0")
PY
)

  if [ "${DRY_RUN:-false}" != true ]; then
    mkdir -p "$RUNTIME_PROJECT_ROOT"
    RUNTIME_PROJECT_ROOT=$(cd "$RUNTIME_PROJECT_ROOT" && pwd)
    local control_dir control_command kimaki_command kimaki_credential_command profile_file
    control_command="$(external_wordpress_control_command)"
    kimaki_command="$(external_wordpress_kimaki_command)"
    kimaki_credential_command="$(external_wordpress_kimaki_credential_command)"
    control_dir="${control_command%/*}"
    profile_file="$(runtime_project_root)/.wp-coding-agents/wordpress.json"
    if [ -L "$(runtime_project_root)/.wp-coding-agents" ]; then
      error "Refusing external runtime state through a symlink: $(runtime_project_root)/.wp-coding-agents"
    fi
    mkdir -p "$control_dir"
    cp "$SCRIPT_DIR/scripts/wp-control-transport.py" "$control_command"
    cp "$SCRIPT_DIR/scripts/external-wordpress-kimaki.py" "$kimaki_command"
    cp "$SCRIPT_DIR/scripts/seed-kimaki-credential.mjs" "$kimaki_credential_command"
    chmod 0755 "$control_command"
    chmod 0755 "$kimaki_command"
    chmod 0755 "$kimaki_credential_command"
    python3 - "$profile_file" "$WORDPRESS_PATH" "${WORDPRESS_USER:-}" <<'PY'
import json, sys
path, wordpress_path, wordpress_user = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"wordpress_path": wordpress_path, "wordpress_user": wordpress_user}, stream, indent=2)
    stream.write("\n")
PY
  fi
}

external_wordpress_validate() {
  [ "${EXTERNAL_WORDPRESS:-false}" = true ] || return 0
  [ "${DRY_RUN:-false}" = true ] && return 0
  wp_cmd core is-installed >/dev/null 2>&1 || error "External WordPress validation failed through the supplied control transport"
}

# Materialize remote Data Machine files locally. Validated paths cannot escape
# the runtime project, and the transport value is never rendered into files.
external_wordpress_project_context() {
  [ "${EXTERNAL_WORDPRESS:-false}" = true ] || return 0
  [ "${DRY_RUN:-false}" = true ] && return 0
  local root parent generations lock lock_owner attempts staging generation raw json record filename layer destination content agent_args=()
  [ -z "${AGENT_SLUG:-}" ] || agent_args=("--agent=$AGENT_SLUG")
  root="$(runtime_project_root)/.wp-coding-agents/context"
  parent="${root%/*}"
  generations="$parent/context-generations"
  lock="$parent/context.lock"
  if [ -L "$parent" ] || [ -L "$generations" ]; then
    error "Refusing projected context through a symlinked runtime state directory"
  fi
  if [ -e "$root" ] && [ ! -L "$root" ]; then
    error "Refusing to replace non-managed projected context: $root"
  fi
  mkdir -p "$parent"
  lock_owner="${BASHPID:-$$}"
  attempts=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -L "$lock" ]; then
      error "Refusing projected context lock through a symlink: $lock"
    fi
    local recorded_owner=""
    [ ! -f "$lock/pid" ] || recorded_owner=$(<"$lock/pid")
    if [ -n "$recorded_owner" ] && ! kill -0 "$recorded_owner" 2>/dev/null; then
      rm -f "$lock/pid"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt 200 ] || error "Timed out waiting for projected context lock"
    sleep 0.05
  done
  printf '%s\n' "$lock_owner" > "$lock/pid"

  raw="$(wp_cmd datamachine memory injectable-files --format=json "${agent_args[@]}" 2>/dev/null)" || error "Could not list injectable Data Machine context through the external control transport"
  json="$(printf '%s\n' "$raw" | sed -n '/^\[/,/^\]/p')"
  [ -n "$json" ] || error "External Data Machine context listing returned no JSON"
  mkdir -p "$generations"
  staging=$(mktemp -d "$generations/.tmp.XXXXXX") || error "Could not create projected context staging directory"
  DM_AGENT_FILES=""
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    filename="${record%%$'\t'*}"
    layer="${record#*$'\t'}"
    case "$filename" in ''|*/*|*'..'*) error "Unsafe injectable context filename: $filename" ;; esac
    case "$layer" in ''|*[!A-Za-z0-9_-]*) error "Unsafe injectable context layer: $layer" ;; esac
    destination="$staging/$layer/$filename"
    mkdir -p "$(dirname "$destination")"
    content="$(wp_cmd datamachine memory read "$filename" "${agent_args[@]}" </dev/null 2>/dev/null)" || error "Could not read injectable Data Machine context '$filename' through the external control transport"
    printf '%s\n' "$content" > "$destination"
    DM_AGENT_FILES="${DM_AGENT_FILES}${DM_AGENT_FILES:+$'\n'}.wp-coding-agents/context/$layer/$filename"
  done < <(printf '%s' "$json" | python3 -c 'import json,sys; [print(item["filename"] + "\t" + item["layer"]) for item in json.load(sys.stdin) if isinstance(item, dict) and isinstance(item.get("filename"), str) and isinstance(item.get("layer"), str)]')
  [ -n "$DM_AGENT_FILES" ] || error "External Data Machine context listing contains no file paths"
  generation="${staging##*/}"
  python3 - "$root" "$parent" "$generations" "$generation" <<'PY' || error "Could not atomically activate projected Data Machine context"
import os
import shutil
import sys

root, parent, generations, generation = sys.argv[1:]
if os.path.islink(parent) or os.path.islink(generations):
    raise SystemExit(1)
if os.path.lexists(root) and not os.path.islink(root):
    raise SystemExit(1)

temporary_link = os.path.join(parent, f".context-link.{os.getpid()}")
try:
    os.symlink(os.path.join("context-generations", generation), temporary_link)
    os.replace(temporary_link, root)
finally:
    if os.path.lexists(temporary_link):
        os.unlink(temporary_link)

for entry in os.scandir(generations):
    if entry.name == generation:
        continue
    if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
        os.unlink(entry.path)
    else:
        shutil.rmtree(entry.path)
PY
  rm -f "$lock/pid"
  rmdir "$lock"
}
