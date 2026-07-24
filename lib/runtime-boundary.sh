#!/bin/bash
# OS-backed write boundary for coding runtimes managed by wp-coding-agents.

runtime_boundary_profile_path() {
  printf '%s/.wp-coding-agents/runtime-boundary.sb' "$(runtime_boundary_site_path)"
}

runtime_boundary_validator_path() {
  printf '%s/.wp-coding-agents/validate-runtime-boundary.py' "$(runtime_boundary_site_path)"
}

runtime_boundary_launcher_path() {
  printf '%s/.wp-coding-agents/run-protected' "$(runtime_boundary_site_path)"
}

runtime_boundary_site_path() {
  if [ "${PLATFORM:-}" = "mac" ]; then
    printf '%s' "$SITE_PATH" | python3 -c 'import os, sys; print(os.path.realpath(sys.stdin.read()), end="")'
  else
    printf '%s' "$SITE_PATH"
  fi
}

runtime_boundary_protected_paths() {
  local site_path
  site_path=$(runtime_boundary_site_path)
  printf '%s\n' \
    "$site_path/wp-admin" \
    "$site_path/wp-includes" \
    "$site_path/wp-content/plugins" \
    "$site_path/wp-content/themes"
}

runtime_boundary_validate_protected_paths() {
  local path
  while IFS= read -r path; do
    [ -d "$path" ] || continue
    if ! python3 - "$path" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
for candidate in root.rglob("*"):
    if not candidate.is_symlink():
        continue
    target = candidate.resolve()
    try:
        target.relative_to(root)
    except ValueError:
        sys.stderr.write(f"protected WordPress source contains an external symlink: {candidate} -> {target}\n")
        raise SystemExit(1)
PY
    then
      return 1
    fi
  done < <(runtime_boundary_protected_paths)
}

runtime_boundary_render_macos_profile() {
  local profile_path path
  profile_path=$(runtime_boundary_profile_path)

  printf '%s\n' '(version 1)' '(allow default)' '(deny file-write*'
  while IFS= read -r path; do
    printf '  (subpath "%s")\n' "$(_runtime_boundary_sandbox_escape "$path")"
  done < <(runtime_boundary_protected_paths)
  printf '  (subpath "%s")\n' "$(_runtime_boundary_sandbox_escape "$(dirname "$profile_path")")"
  printf '%s\n' ')'
}

_runtime_boundary_sandbox_escape() {
  printf '%s' "$1" | python3 -c 'import sys; print(sys.stdin.read().replace("\\", "\\\\").replace("\"", "\\\""), end="")'
}

runtime_boundary_install() {
  runtime_boundary_validate_protected_paths || return 1

  local profile_path profile_dir validator_path validator_content
  profile_path=$(runtime_boundary_profile_path)
  profile_dir=$(dirname "$profile_path")
  validator_path=$(runtime_boundary_validator_path)
  validator_content='#!/usr/bin/env python3
import pathlib
import sys

site = pathlib.Path(sys.argv[1]).resolve()
for relative in ("wp-admin", "wp-includes", "wp-content/plugins", "wp-content/themes"):
    root = (site / relative).resolve()
    if not root.is_dir():
        continue
    for candidate in root.rglob("*"):
        if not candidate.is_symlink():
            continue
        target = candidate.resolve()
        try:
            target.relative_to(root)
        except ValueError:
            sys.stderr.write(f"protected WordPress source contains an external symlink: {candidate} -> {target}\n")
            raise SystemExit(1)'

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install runtime write-boundary preflight at $validator_path"
    if [ "${PLATFORM:-}" = "mac" ]; then
      echo -e "${BLUE}[dry-run]${NC} Would install runtime write boundary at $profile_path"
    fi
    return 0
  fi

  mkdir -p "$profile_dir"
  chmod u+w "$profile_dir" 2>/dev/null || true
  _runtime_boundary_install_file "$validator_path" 0555 "$validator_content"

  if [ "${PLATFORM:-}" = "mac" ]; then
    local profile_content launcher_path launcher_content
    profile_content=$(runtime_boundary_render_macos_profile)
    launcher_path=$(runtime_boundary_launcher_path)
    printf -v launcher_content '#!/bin/bash\nset -e\n/usr/bin/python3 %q %q\nexec /usr/bin/sandbox-exec -f %q "$@"' \
      "$validator_path" "$(runtime_boundary_site_path)" "$profile_path"
    _runtime_boundary_install_file "$profile_path" 0444 "$profile_content"
    _runtime_boundary_install_file "$launcher_path" 0555 "$launcher_content"
  fi

  chmod 0555 "$profile_dir"
  log "Installed runtime write-boundary preflight: $validator_path"
  if [ -n "${UPDATED_ITEMS+x}" ]; then
    UPDATED_ITEMS+=("runtime write boundary")
  fi
}

_runtime_boundary_install_file() {
  local path="$1" mode="$2" content="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    chmod "$mode" "$path"
    return 0
  fi

  chmod u+w "$path" 2>/dev/null || true
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

runtime_boundary_systemd_directives() {
  local path
  printf '%s\n' \
    'NoNewPrivileges=true' \
    'PrivateMounts=true' \
    'PrivateDevices=true' \
    'CapabilityBoundingSet=' \
    'AmbientCapabilities=' \
    'ProtectProc=invisible' \
    'ProcSubset=pid'
  printf 'ExecStartPre=/usr/bin/python3 "%s" "%s"\n' "$(runtime_boundary_validator_path)" "$(runtime_boundary_site_path)"
  while IFS= read -r path; do
    printf 'ReadOnlyPaths=%s\n' "$path"
  done < <(runtime_boundary_protected_paths)
}

runtime_boundary_macos_plist_prefix() {
  cat <<EOF
        <string>$(runtime_boundary_launcher_path)</string>
EOF
}

runtime_boundary_start_command() {
  local runtime_bin="$1"
  if [ "${PLATFORM:-}" = "mac" ]; then
    printf 'cd %q && %q %q' "$SITE_PATH" "$(runtime_boundary_launcher_path)" "$runtime_bin"
  else
    printf 'cd %q && %q' "$SITE_PATH" "$runtime_bin"
  fi
}
