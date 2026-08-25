#!/bin/bash
# bridges/kimaki.sh — Kimaki Discord bridge.
#
# Owns install (local launchd / VPS systemd / Linux-local manual), upgrade-time
# config sync (plugins, post-upgrade.sh, skill allowlist, regression test),
# systemd + launchd template rendering, summary blocks, and the per-bridge
# assets at bridges/kimaki/ (plugins/, post-upgrade.sh, skills-enable-list.txt).
#
# Install layout:
#   VPS:   /opt/kimaki-config/{plugins,post-upgrade.sh,skills-enable-list.txt}
#          + /etc/systemd/system/kimaki.service (ExecStartPre runs post-upgrade.sh)
#   Local: $KIMAKI_DATA_DIR/kimaki-config/ for plugins, post-upgrade.sh,
#          launchd-start.sh, and skill filters. launchd-start.sh gives macOS
#          the same pre-start cleanup/post-upgrade hook that systemd gets from
#          ExecStartPre. opencode.json loads plugins directly from this durable
#          data-dir copy because `npm update -g kimaki` wipes package-local
#          files.
#          + $HOME/Library/LaunchAgents/com.wp.kimaki.plist on macOS.

# ============================================================================
# Identity
# ============================================================================

bridge_systemd_units()  { echo "${KIMAKI_UNIT:-kimaki.service}"; }
bridge_launchd_labels() { echo "com.wp.kimaki"; }
bridge_binaries()       { echo "kimaki"; }
bridge_display_name()   { echo "kimaki"; }
bridge_display_title()  { echo "Kimaki"; }

bridge_is_ready() {
  [ -n "${KIMAKI_BOT_TOKEN:-}" ]
}

_kimaki_unit_env_value() {
  local unit_file="$1" key="$2"
  sed -n "s/^Environment=${key}=//p" "$unit_file" | head -1
}

_kimaki_unit_exec_arg() {
  local unit_file="$1" flag="$2" line rest
  line=$(grep '^ExecStart=' "$unit_file" | head -1 || true)
  rest="${line#* $flag }"
  [ "$rest" != "$line" ] || return 0
  printf '%s\n' "${rest%% *}"
}

_kimaki_validate_lock_port() {
  [ -z "${KIMAKI_LOCK_PORT:-}" ] && return 0
  case "$KIMAKI_LOCK_PORT" in *[!0-9]*) error "Invalid Kimaki lock port '$KIMAKI_LOCK_PORT'" ;; esac
  if [ "$KIMAKI_LOCK_PORT" -lt 1 ] || [ "$KIMAKI_LOCK_PORT" -gt 65535 ]; then
    error "Invalid Kimaki lock port '$KIMAKI_LOCK_PORT' (expected 1-65535)"
  fi
}

_kimaki_normalize_unit_name() {
  local unit="$1" stem
  [ -n "$unit" ] || error "Invalid Kimaki unit: name cannot be empty"
  case "$unit" in
    *.service) ;;
    *) unit="$unit.service" ;;
  esac
  case "$unit" in
    */*|*\\*|*..*|*[!A-Za-z0-9_.@-]*)
      error "Invalid Kimaki unit '$unit' (expected a traversal-safe unit basename)"
      ;;
  esac
  stem="${unit%.service}"
  case "$stem" in
    kimaki|kimaki-?*) ;;
    *) error "Invalid Kimaki unit '$unit' (expected kimaki.service or kimaki-<name>.service)" ;;
  esac
  printf '%s\n' "$unit"
}

_kimaki_remove_systemd_env_key() {
  local env_block="$1" key="$2"
  printf '%s\n' "$env_block" | grep -v "^Environment=${key}=" || true
}

# Select an installed Kimaki instance by exact WordPress WorkingDirectory.
# Explicit inputs win; otherwise zero matches keeps the legacy default only
# when no Kimaki unit exists, one match is adopted, and ambiguity is fatal.
_kimaki_resolve_instance() {
  local unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local requested
  requested=$(_kimaki_normalize_unit_name "${KIMAKI_UNIT-}")
  KIMAKI_UNIT="$requested"

  local unit working normalized_site="$SITE_PATH" matches=() installed=()
  if [ -d "$SITE_PATH" ]; then
    normalized_site=$(cd "$SITE_PATH" 2>/dev/null && pwd -P || printf '%s' "$SITE_PATH")
  fi

  if [ "${KIMAKI_UNIT_EXPLICIT:-false}" != true ]; then
    for unit in "$unit_dir"/kimaki*.service; do
      [ -f "$unit" ] || continue
      installed+=("$unit")
      working=$(sed -n 's/^WorkingDirectory=//p' "$unit" | head -1)
      [ -n "$working" ] || continue
      if [ -d "$working" ]; then
        working=$(cd "$working" 2>/dev/null && pwd -P || printf '%s' "$working")
      fi
      [ "$working" = "$normalized_site" ] && matches+=("$unit")
    done
    if [ ${#matches[@]} -eq 1 ]; then
      KIMAKI_UNIT=$(basename "${matches[0]}")
      log "  Selected $KIMAKI_UNIT for WorkingDirectory=$SITE_PATH"
    elif [ ${#matches[@]} -gt 1 ]; then
      error "Multiple Kimaki units target $SITE_PATH: ${matches[*]}. Pass --kimaki-unit <unit>."
    elif [ ${#installed[@]} -gt 0 ]; then
      error "No Kimaki unit targets $SITE_PATH. Pass --kimaki-unit <unit> to select or create one. Installed: ${installed[*]}"
    fi
  fi

  local unit_file="$unit_dir/$KIMAKI_UNIT"
  if [ ! -f "$unit_file" ]; then
    _kimaki_validate_lock_port
    return 0
  fi

  local value unit_user unit_home
  unit_user=$(_systemd_unit_user "$unit_file" || true)
  unit_home=$(_kimaki_unit_env_value "$unit_file" HOME)
  if [ "${SERVICE_USER_FORCED:-false}" != true ] && [ -n "$unit_user" ]; then
    SERVICE_USER="$unit_user"
    [ -n "$unit_home" ] || unit_home=$(getent passwd "$unit_user" 2>/dev/null | cut -d: -f6)
    [ -n "$unit_home" ] || { [ "$unit_user" = root ] && unit_home=/root || unit_home="/home/$unit_user"; }
    SERVICE_HOME="$unit_home"
    [ "$unit_user" = root ] && RUN_AS_ROOT=true || RUN_AS_ROOT=false
  fi

  if [ "${KIMAKI_DATA_DIR_EXPLICIT:-false}" != true ]; then
    value=$(_kimaki_unit_env_value "$unit_file" KIMAKI_DATA_DIR)
    [ -n "$value" ] || value=$(_kimaki_unit_exec_arg "$unit_file" --data-dir)
    if [ -n "$value" ]; then
      KIMAKI_DATA_DIR="$value"
    else
      KIMAKI_DATA_DIR="$SERVICE_HOME/.kimaki"
    fi
  fi
  if [ "${KIMAKI_LOCK_PORT_EXPLICIT:-false}" != true ]; then
    value=$(_kimaki_unit_env_value "$unit_file" KIMAKI_LOCK_PORT)
    [ -n "$value" ] || value=$(_kimaki_unit_exec_arg "$unit_file" --lock-port)
    KIMAKI_LOCK_PORT="$value"
  fi
  if [ -z "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG=$(_kimaki_unit_env_value "$unit_file" DATAMACHINE_AGENT_SLUG)
  fi
  _kimaki_validate_lock_port
}

_kimaki_instance_suffix() {
  local unit="${KIMAKI_UNIT:-kimaki.service}"
  [ "$unit" = "kimaki.service" ] && return 0
  unit="${unit%.service}"
  unit="${unit#kimaki-}"
  printf -- '-%s' "$unit"
}

# ============================================================================
# Install (setup-time)
# ============================================================================

bridge_install() {
  if ! command -v kimaki &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g kimaki
  else
    log "Kimaki already installed: $(command -v kimaki)"
  fi

  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    _kimaki_seed_external_credential
    log "External WordPress profile: Kimaki installed. Start it from the runtime environment with:"
    log "  WP_CONTROL_TRANSPORT_JSON='<argv-json>' $(external_wordpress_kimaki_command)"
  elif [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    _kimaki_install_launchd
  elif [ "$LOCAL_MODE" = true ]; then
    log "Local mode: Kimaki installed. Run manually with:"
    log "  cd $SITE_PATH && kimaki"
  else
    _kimaki_install_systemd
  fi

  _kimaki_sync_bin_helpers
  [ "${EXTERNAL_WORDPRESS:-false}" != true ] || return 0
  _kimaki_register_cli_channel
  _kimaki_register_runtime_signature
}

_kimaki_seed_external_credential() {
  [ -n "${KIMAKI_BOT_TOKEN:-}" ] || return 0
  [ -n "${KIMAKI_DATA_DIR:-}" ] || error "KIMAKI_DATA_DIR is required to seed an external Kimaki credential"

  local helper
  helper="$(external_wordpress_kimaki_credential_command)"
  [ "${DRY_RUN:-false}" = true ] || [ -x "$helper" ] || error "Managed Kimaki credential helper is unavailable: $helper"
  run_cmd node "$helper"
  log "External Kimaki credential configured"
}

# _kimaki_register_cli_channel
#
# Register kimaki with the wp-coding-agents CLI transport runtime so that
# `agents/dispatch-message` (substrate: Automattic/agents-api) can deliver
# messages to Discord channels by shelling kimaki. `recipient` is the Discord
# channel ID (numeric string) the message is delivered to. `message` is the
# message body.
#
# Register the native Kimaki binary on local installs. On VPS installs, register
# a stable dispatch wrapper that sudo-hops to the adopted service user before it
# execs Kimaki. Kimaki 0.13 validates requested agents and falls back to the
# default/build agent when a requested agent is unavailable, so wp-coding-agents
# must not rewrite `--agent` itself.
#
# The command we register here is shelled by the Data Machine Code CLI transport
# from the `agents/dispatch-message` ability, which runs inside PHP-FPM as the
# WordPress web user (www-data) on WP-cron / Action Scheduler fires — NOT as the
# kimaki.service user. On a RUN_AS_ROOT install the kimaki binary resolves under
# /root/.kimaki/bin (and the data dir under /root, mode 0700); www-data cannot
# traverse 0700 /root, so proc_open fails with EACCES and every scheduled
# dispatch dies as datamachine_code_cli_dispatch_spawn_failed. The opencode
# service-user home (/home/opencode, mode 0750) is the same trap. We therefore
# only register a path whose ancestor directories are world-traversable
# (`o+x`), preferring a system-prefix binary (e.g. /usr/bin/kimaki, the
# npm-global symlink) over any private-home wrapper. See #198 / #93.
_kimaki_register_cli_channel() {
  local cmd
  if [ "${LOCAL_MODE:-false}" != true ] && [ -n "${SERVICE_USER:-}" ] && [ "$SERVICE_USER" != "root" ]; then
    cmd="/usr/local/bin/wp-coding-agents-kimaki$(_kimaki_instance_suffix)-dispatch"
  elif [ -n "${KIMAKI_BIN:-}" ] \
    && [ -x "$KIMAKI_BIN" ] \
    && ! _kimaki_is_legacy_adapter_file "$KIMAKI_BIN" \
    && _kimaki_path_is_web_traversable "$KIMAKI_BIN"; then
    cmd="$KIMAKI_BIN"
  else
    cmd="$(_kimaki_find_native_binary)"
  fi

  # Stamp the spawned kimaki's HOME + data-dir into the channel block so local
  # dispatch does not inherit an unwritable caller HOME. VPS dispatch uses the
  # wrapper installed by _kimaki_install_dispatch_helpers, which sudo-hops to
  # SERVICE_USER before applying the same HOME/KIMAKI_DATA_DIR values; keeping
  # them here is harmless defense-in-depth and preserves operator visibility.
  local service_home="${SERVICE_HOME:-}"
  local data_dir="${KIMAKI_DATA_DIR:-}"
  local env_json=""
  if [ -n "$service_home" ]; then
    [ -n "$data_dir" ] || data_dir="$service_home/.kimaki"
    env_json="{\"HOME\":\"${service_home}\",\"KIMAKI_DATA_DIR\":\"${data_dir}\"}"
  fi

  cli_channel_register \
    "kimaki" \
    "$cmd" \
    '["send","--channel","{recipient}","--prompt","{message}"]' \
    "600" \
    "$env_json"
}

_kimaki_is_legacy_adapter_file() {
  local file="$1"
  [ -e "$file" ] && grep -q 'wp-coding-agents datamachine-kimaki adapter' "$file" 2>/dev/null
}

# _kimaki_path_is_web_traversable <path>
#
# Return 0 if every ancestor directory of <path> carries the world-execute
# bit (`o+x`), i.e. an unrelated user (the PHP-FPM web user that runs the
# CLI-dispatch transport) can traverse to it. Return 1 if any ancestor is
# missing `o+x` (e.g. /root at 0700, /home/opencode at 0750) — such a path is
# unreachable by www-data and must not be registered as the dispatch command.
#
# Symlinks are resolved first (via realpath when available) so the real
# target's ancestors are checked, not the link's. If the path cannot be
# resolved or stat'd, err on the side of "not traversable" (return 1) so the
# caller falls back to PATH resolution.
_kimaki_path_is_web_traversable() {
  local path="$1"
  [ -n "$path" ] || return 1

  local resolved
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath -e "$path" 2>/dev/null)" \
      || resolved="$(realpath "$path" 2>/dev/null)" \
      || return 1
  elif command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$path" 2>/dev/null)" || return 1
  else
    resolved="$path"
  fi
  [ -n "$resolved" ] || return 1

  # Walk every ancestor directory from the binary up to /, asserting o+x.
  local dir="${resolved%/*}"
  [ -n "$dir" ] || dir="/"
  while :; do
    local perms
    perms="$(stat -c '%a' "$dir" 2>/dev/null)" || perms="$(stat -f '%Lp' "$dir" 2>/dev/null)" || return 1
    # Last octal digit is the "other" triad; its execute bit is value 1.
    local other="${perms: -1}"
    case "$other" in
      1|3|5|7) ;;            # o+x present
      *) return 1 ;;          # o+x missing — not traversable by www-data
    esac
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -n "$dir" ] || dir="/"
  done

  return 0
}

# _kimaki_find_native_binary
#
# Resolve the kimaki binary to register as the CLI-dispatch command. Walks
# $PATH and returns the first candidate that is (a) executable, (b) not the
# legacy adapter shim, and (c) web-traversable (every ancestor dir is `o+x`,
# so the www-data CLI-dispatch transport can reach it — see #198).
#
# A candidate that is executable but trapped under a private home
# (/root/.kimaki/bin, /home/opencode/.kimaki/bin) is skipped in favor of a
# later, reachable candidate (typically the /usr/bin npm-global symlink). If
# nothing on $PATH is reachable, fall back to the bare name "kimaki" and let
# the runtime resolve it via its own PATH at dispatch time.
_kimaki_find_native_binary() {
  local dir candidate first_unreachable=""
  IFS=: read -r -a path_entries <<< "${PATH:-}"
  for dir in "${path_entries[@]}"; do
    [ -n "$dir" ] || continue
    candidate="$dir/kimaki"
    [ -x "$candidate" ] || continue
    if _kimaki_is_legacy_adapter_file "$candidate"; then
      continue
    fi
    if ! _kimaki_path_is_web_traversable "$candidate"; then
      # Remember the first executable-but-unreachable candidate as a
      # last-resort over the bare name, but keep looking for a reachable one.
      [ -n "$first_unreachable" ] || first_unreachable="$candidate"
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done

  if [ -n "$first_unreachable" ]; then
    printf '%s\n' "$first_unreachable"
    return 0
  fi

  printf '%s\n' "kimaki"
}

# _kimaki_register_runtime_signature
#
# Kimaki does not currently export stable session/thread/channel attribution env
# vars to OpenCode/tool subprocesses. Register the documented upstream #137
# contract now so the DMC worktree signature and the invocation-scoped Homeboy
# notification adapter consume the same values when Kimaki starts exporting them.
# Until then both consumers remain fail-closed.
# https://github.com/remorses/kimaki/issues/137
_kimaki_register_runtime_signature() {
  if ! declare -F runtime_signature_register >/dev/null; then
    return 0
  fi

  runtime_signature_register \
    "kimaki" \
    '{"session_id":"KIMAKI_SESSION_ID","thread_id":"KIMAKI_THREAD_ID","channel_id":"KIMAKI_CHANNEL_ID"}'
}

_kimaki_sync_bin_helpers() {
  local HELPER_DIR
  if [ "$LOCAL_MODE" = true ]; then
    HELPER_DIR="$SERVICE_HOME/.local/bin"
  else
    HELPER_DIR="/usr/local/bin"
  fi

  _kimaki_remove_legacy_session_helper "$HELPER_DIR"
  _kimaki_remove_legacy_command_shims "$HELPER_DIR"
  _kimaki_remove_obsolete_homeboy_notification_helper "$HELPER_DIR"
  _kimaki_install_dispatch_helpers
}

_kimaki_remove_obsolete_homeboy_notification_helper() {
  local helper_dir="$1"
  local target="$helper_dir/wp-coding-agents-homeboy-notification"

  [ -e "$target" ] || return 0
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would remove obsolete $target"
    return 0
  fi

  rm -f "$target"
  log "  Removed obsolete $target"
  UPDATED_ITEMS+=("removed obsolete wp-coding-agents-homeboy-notification helper")
}

_kimaki_install_dispatch_helpers() {
  if [ "${LOCAL_MODE:-false}" = true ] || [ -z "${SERVICE_USER:-}" ] || [ "$SERVICE_USER" = "root" ]; then
    return 0
  fi

  local suffix
  suffix=$(_kimaki_instance_suffix)
  local dispatch_wrapper="${KIMAKI_DISPATCH_WRAPPER_DIR:-/usr/local/bin}/wp-coding-agents-kimaki${suffix}-dispatch"
  local target_helper="${KIMAKI_DISPATCH_TARGET_DIR:-/usr/local/lib/wp-coding-agents}/kimaki${suffix}-dispatch-target"
  local sudoers_file="${KIMAKI_DISPATCH_SUDOERS_DIR:-/etc/sudoers.d}/wp-coding-agents-kimaki${suffix}-dispatch"
  local service_home="${SERVICE_HOME:-}"
  local data_dir="${KIMAKI_DATA_DIR:-}"
  local kimaki_bin="${KIMAKI_BIN:-}"
  local path_value="${PATH:-/usr/local/bin:/usr/bin:/bin}"

  [ -n "$service_home" ] || service_home="/home/$SERVICE_USER"
  [ -n "$data_dir" ] || data_dir="$service_home/.kimaki"
  if [ -z "$kimaki_bin" ] || [ "$kimaki_bin" = "$dispatch_wrapper" ]; then
    kimaki_bin="$(_kimaki_find_native_binary)"
  fi

  local service_home_q data_dir_q kimaki_bin_q path_q target_helper_q service_user_q
  service_home_q=$(_kimaki_shell_quote "$service_home")
  data_dir_q=$(_kimaki_shell_quote "$data_dir")
  kimaki_bin_q=$(_kimaki_shell_quote "$kimaki_bin")
  path_q=$(_kimaki_shell_quote "$path_value")
  target_helper_q=$(_kimaki_shell_quote "$target_helper")
  service_user_q=$(_kimaki_shell_quote "$SERVICE_USER")

  local target_content wrapper_content sudoers_content
  target_content="#!/bin/sh
set -eu
export HOME=$service_home_q
export KIMAKI_DATA_DIR=$data_dir_q
export PATH=$path_q
exec $kimaki_bin_q \"\$@\""

  wrapper_content="#!/bin/sh
set -eu
exec sudo -n -H -u $service_user_q $target_helper_q \"\$@\""

  sudoers_content=$(_kimaki_dispatch_sudoers_content "$SERVICE_USER" "$target_helper")

  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would install $target_helper"
    echo -e "${BLUE}[dry-run]${NC} Would install $dispatch_wrapper"
    echo -e "${BLUE}[dry-run]${NC} Would install $sudoers_file"
    return 0
  fi

  if [ "$(_kimaki_effective_uid)" -ne 0 ]; then
    if _kimaki_dispatch_helpers_match \
      "$target_helper" "$target_content" \
      "$dispatch_wrapper" "$wrapper_content" \
      "$sudoers_file" "$sudoers_content" \
      && _kimaki_validate_dispatch_callers "$dispatch_wrapper" "$SERVICE_USER"; then
      log "  Keeping functional root-owned Kimaki dispatch wrapper for $SERVICE_USER"
      return 0
    fi

    _kimaki_report_dispatch_root_repair_required
    return 0
  fi

  install -d -m 0755 "$(dirname "$target_helper")"
  printf '%s\n' "$target_content" > "$target_helper"
  chown root:root "$target_helper"
  chmod 0755 "$target_helper"

  printf '%s\n' "$wrapper_content" > "$dispatch_wrapper"
  chown root:root "$dispatch_wrapper"
  chmod 0755 "$dispatch_wrapper"

  printf '%s\n' "$sudoers_content" > "$sudoers_file"
  chown root:root "$sudoers_file"
  chmod 0440 "$sudoers_file"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$sudoers_file" >/dev/null
  fi

  if ! _kimaki_dispatch_helpers_match \
    "$target_helper" "$target_content" \
    "$dispatch_wrapper" "$wrapper_content" \
    "$sudoers_file" "$sudoers_content"; then
    error "Kimaki dispatch helper validation failed after root installation"
  fi
  if ! _kimaki_validate_dispatch_callers "$dispatch_wrapper" "$SERVICE_USER"; then
    error "Kimaki dispatch wrapper validation failed for www-data or $SERVICE_USER"
  fi

  log "  Installed Kimaki dispatch wrapper: $dispatch_wrapper → $SERVICE_USER"
  UPDATED_ITEMS+=("Kimaki dispatch wrapper")
}

_kimaki_effective_uid() {
  printf '%s\n' "${WP_CODING_AGENTS_TEST_EUID:-$(id -u)}"
}

_kimaki_dispatch_helpers_match() {
  local target_helper="$1" target_content="$2"
  local dispatch_wrapper="$3" wrapper_content="$4"
  local sudoers_file="$5" sudoers_content="$6"

  [ -x "$target_helper" ] \
    && [ -x "$dispatch_wrapper" ] \
    && [ -r "$sudoers_file" ] \
    && printf '%s\n' "$target_content" | cmp -s - "$target_helper" \
    && printf '%s\n' "$wrapper_content" | cmp -s - "$dispatch_wrapper" \
    && printf '%s\n' "$sudoers_content" | cmp -s - "$sudoers_file"
}

_kimaki_dispatch_caller_can_execute() {
  local caller="$1" dispatch_wrapper="$2"
  local invoking_user
  invoking_user=$(id -un 2>/dev/null || true)

  if [ "$invoking_user" = "$caller" ]; then
    "$dispatch_wrapper" --version >/dev/null 2>&1
    return $?
  fi

  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n -H -u "$caller" "$dispatch_wrapper" --version >/dev/null 2>&1
}

_kimaki_validate_dispatch_callers() {
  local dispatch_wrapper="$1" service_user="$2"
  local caller seen=""

  for caller in www-data "$service_user"; do
    [ -n "$caller" ] || continue
    case " $seen " in *" $caller "*) continue ;; esac
    seen="$seen $caller"
    _kimaki_dispatch_caller_can_execute "$caller" "$dispatch_wrapper" || return 1
  done
}

_kimaki_dispatch_repair_command() {
  local command
  printf -v command 'sudo -- %q --kimaki-only --wp-path %q --kimaki-unit %q' \
    "$SCRIPT_DIR/upgrade.sh" "$SITE_PATH" "${KIMAKI_UNIT:-kimaki.service}"
  printf '%s\n' "$command"
}

_kimaki_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

_kimaki_report_dispatch_root_repair_required() {
  KIMAKI_DISPATCH_ROOT_REPAIR_REQUIRED=true
  KIMAKI_DISPATCH_ROOT_REPAIR_COMMAND=$(_kimaki_dispatch_repair_command)

  warn "  Kimaki dispatch helpers could not be certified for www-data and $SERVICE_USER."
  warn "  Root repair required: $KIMAKI_DISPATCH_ROOT_REPAIR_COMMAND"
  printf '{"status":"root_repair_required","component":"kimaki_dispatch_helpers","repair_command":"%s"}\n' \
    "$(_kimaki_json_escape "$KIMAKI_DISPATCH_ROOT_REPAIR_COMMAND")"
}

_kimaki_dispatch_sudoers_content() {
  local service_user="$1"
  local target_helper="$2"
  local caller
  local seen_callers=""

  for caller in www-data "$service_user"; do
    [ -n "$caller" ] || continue
    case "
$seen_callers
" in
      *"
$caller
"*) continue ;;
    esac
    seen_callers="${seen_callers:-}
$caller"
    printf '%s ALL=(%s) NOPASSWD: %s *\n' "$caller" "$service_user" "$target_helper"
  done
}

_kimaki_shell_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

_kimaki_remove_legacy_session_helper() {
  local helper_dir="$1"
  local legacy_helper="$helper_dir/datamachine-kimaki-session"

  [ -e "$legacy_helper" ] || return 0

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would remove legacy $legacy_helper"
    return 0
  fi

  rm -f "$legacy_helper"
  log "  Removed legacy $legacy_helper"
  UPDATED_ITEMS+=("removed datamachine-kimaki-session helper")
}

_kimaki_remove_legacy_command_shims() {
  local helper_dir="$1"
  local adapter_target="$helper_dir/datamachine-kimaki"
  local shim_target="$helper_dir/kimaki"

  if [ "$DRY_RUN" = true ]; then
    if _kimaki_is_legacy_adapter_file "$adapter_target"; then
      echo -e "${BLUE}[dry-run]${NC} Would remove legacy $adapter_target"
    fi
    if _kimaki_is_legacy_adapter_file "$shim_target"; then
      echo -e "${BLUE}[dry-run]${NC} Would remove legacy $shim_target"
    fi
    return 0
  fi

  if _kimaki_is_legacy_adapter_file "$adapter_target"; then
    rm -f "$adapter_target"
    log "  Removed legacy $adapter_target"
    UPDATED_ITEMS+=("removed legacy datamachine-kimaki adapter")
  fi
  if _kimaki_is_legacy_adapter_file "$shim_target"; then
    rm -f "$shim_target"
    log "  Removed legacy $shim_target"
    UPDATED_ITEMS+=("removed legacy kimaki command shim")
  fi

  if [ "${KIMAKI_BIN:-}" = "$shim_target" ]; then
    KIMAKI_BIN="$(_kimaki_find_native_binary)"
  fi
}

_kimaki_install_launchd() {
  KIMAKI_PLIST_LABEL="com.wp.kimaki"
  KIMAKI_PLIST_DIR="$HOME/Library/LaunchAgents"
  KIMAKI_PLIST="$KIMAKI_PLIST_DIR/$KIMAKI_PLIST_LABEL.plist"

  if [ "$DRY_RUN" = true ]; then
    KIMAKI_BIN="/opt/homebrew/bin/kimaki"
  else
    KIMAKI_BIN=$(_kimaki_resolve_service_bin "/opt/homebrew/bin/kimaki")
  fi

  run_cmd mkdir -p "$KIMAKI_DATA_DIR"
  run_cmd mkdir -p "$KIMAKI_PLIST_DIR"

  local KIMAKI_CONFIG_DIR="${KIMAKI_DATA_DIR}/kimaki-config"
  if [ "$DRY_RUN" = false ] && [ -f "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" ]; then
    mkdir -p "$KIMAKI_CONFIG_DIR"
    cp "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" "$KIMAKI_CONFIG_DIR/launchd-start.sh"
    chmod +x "$KIMAKI_CONFIG_DIR/launchd-start.sh"
    cp "$SCRIPT_DIR/bridges/kimaki/restart-continuation.py" "$KIMAKI_CONFIG_DIR/restart-continuation.py"
    chmod +x "$KIMAKI_CONFIG_DIR/restart-continuation.py"
  fi

  write_file "$KIMAKI_PLIST" "$(bridge_render_launchd "$KIMAKI_PLIST_LABEL")"

  if [ "$DRY_RUN" = false ] && [ -n "$KIMAKI_BOT_TOKEN" ]; then
    launchctl bootout "gui/$(id -u)" "$KIMAKI_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$KIMAKI_PLIST"
    log "Kimaki launchd service installed and started"
  elif [ "$DRY_RUN" = false ]; then
    log "KIMAKI_BOT_TOKEN not set — service not started"
    log "Run onboarding first, then enable the service:"
    log "  cd $SITE_PATH && kimaki"
    log "  launchctl bootstrap gui/$(id -u) $KIMAKI_PLIST"
  fi

  log "Kimaki service: $KIMAKI_PLIST_LABEL"
  log "  Start:  launchctl kickstart gui/$(id -u)/$KIMAKI_PLIST_LABEL"
  log "  Stop:   launchctl kill SIGTERM gui/$(id -u)/$KIMAKI_PLIST_LABEL"
  log "  Logs:   tail -f $KIMAKI_DATA_DIR/kimaki.log"
}

# _kimaki_resolve_service_bin
#
# Resolve the kimaki binary that goes into ExecStart / ProgramArguments using
# the ADOPTED service identity (SERVICE_USER / SERVICE_HOME), never the
# invoking shell's $PATH. This is the fix for #232: upgrade.sh runs as root,
# but adopt_service_identity_from_units() (bridges/_dispatch.sh) may have
# already re-derived SERVICE_USER=opencode / SERVICE_HOME=/home/opencode from
# the existing unit. A bare `which kimaki` resolves against root's PATH and
# leaks /root/.kimaki/bin/kimaki into a unit that runs as opencode and writes
# HOME=/home/opencode — an internally inconsistent unit whose ExecStart the
# service user cannot read, crashing the bridge on the next restart.
#
# Resolution order (issue option order — prefer a stable, identity-consistent
# path over the invoking user's private home):
#   1. A system-prefix binary (/usr/bin, /usr/local/bin, /opt/homebrew/bin):
#      reachable by any service user, the npm-global symlink target the
#      installer already prefers (see _kimaki_register_cli_channel, ~line 80).
#   2. When SERVICE_USER differs from the invoking user, resolve UNDER the
#      service user: `sudo -n -H -u "$SERVICE_USER" env HOME="$SERVICE_HOME"
#      bash -lc 'command -v kimaki'` (mirrors lib/homeboy.sh:40). Guarded for
#      sudo availability / non-zero exit.
#   3. $SERVICE_HOME/.kimaki/bin/kimaki if that file exists (the canonical
#      per-user install layout, derived from the adopted home — never /root).
#   4. /usr/bin/kimaki as a last-resort stable default.
#
# Args: $1 = fallback system-prefix default (e.g. /usr/bin/kimaki on Linux,
#            /opt/homebrew/bin/kimaki on macOS).
_kimaki_resolve_service_bin() {
  local default_bin="${1:-/usr/bin/kimaki}"
  local candidate

  # 1. Stable system-prefix binary — reachable by any service user. The list
  #    is overridable (space-separated) only so tests can point it at a temp
  #    prefix and exercise the service-user / SERVICE_HOME fallback paths
  #    deterministically; production always uses the real system prefixes.
  local system_bins="${KIMAKI_SYSTEM_PREFIX_BINS:-/usr/bin/kimaki /usr/local/bin/kimaki /opt/homebrew/bin/kimaki}"
  for candidate in $system_bins; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  # 2. Resolve under the adopted service user when it differs from the
  #    invoking user (the root-upgrade-against-opencode-unit case).
  local invoking_user running_as_root=false
  invoking_user="$(id -un 2>/dev/null || echo "")"
  if [ "${WP_CODING_AGENTS_TEST_ASSUME_ROOT:-false}" = true ] || [ "$(id -u)" -eq 0 ]; then
    running_as_root=true
  fi
  if [ "${LOCAL_MODE:-false}" != true ] \
    && [ -n "${SERVICE_USER:-}" ] \
    && [ "$SERVICE_USER" != "$invoking_user" ] \
    && [ -n "${SERVICE_HOME:-}" ] \
    && [ "$running_as_root" = true ] \
    && command -v sudo >/dev/null 2>&1; then
    candidate="$(sudo -n -H -u "$SERVICE_USER" env HOME="$SERVICE_HOME" bash -lc 'command -v kimaki' 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # 3. Canonical per-user install layout under the ADOPTED home (not /root).
  if [ -n "${SERVICE_HOME:-}" ] && [ -f "$SERVICE_HOME/.kimaki/bin/kimaki" ]; then
    printf '%s\n' "$SERVICE_HOME/.kimaki/bin/kimaki"
    return 0
  fi

  # 4. Last-resort stable default.
  printf '%s\n' "$default_bin"
}

# _kimaki_assert_bin_identity <kimaki_bin> <path_value>
#
# Cheap guard requested by #232: after resolving KIMAKI_BIN / PATH_VALUE,
# assert that the binary and any `.kimaki/bin` PATH segment live under the
# adopted $SERVICE_HOME OR a system prefix. If either references a DIFFERENT
# user's home, warn loudly rather than silently writing a mismatched unit.
# Never fatal — the unit is still written, but the operator sees the warning
# in the upgrade output and can intervene before the next restart.
_kimaki_assert_bin_identity() {
  local kimaki_bin="$1" path_value="$2"
  local home="${SERVICE_HOME:-}"

  _kimaki_path_under_allowed_home() {
    local path="$1"
    case "$path" in
      /usr/bin/*|/usr/local/bin/*|/opt/homebrew/bin/*) return 0 ;;
    esac
    if [ -n "$home" ]; then
      case "$path" in
        "$home"/*) return 0 ;;
      esac
    fi
    return 1
  }

  if ! _kimaki_path_under_allowed_home "$kimaki_bin"; then
    warn "  kimaki binary '$kimaki_bin' is NOT under SERVICE_HOME ($home) or a system prefix"
    warn "  the rendered unit runs as User=${SERVICE_USER:-?} and may not be able to read it (see #232)"
  fi

  # Inspect every PATH segment that points at a per-user .kimaki/bin: it must
  # belong to the adopted home, not another user's (e.g. /root/.kimaki/bin).
  local seg
  local IFS=:
  for seg in $path_value; do
    case "$seg" in
      */.kimaki/bin)
        if ! _kimaki_path_under_allowed_home "$seg"; then
          warn "  PATH segment '$seg' references a different user's home than SERVICE_HOME ($home) (see #232)"
        fi
        ;;
    esac
  done

  unset -f _kimaki_path_under_allowed_home
}

_kimaki_install_systemd() {
  KIMAKI_CONFIG_DIR="/opt/kimaki-config"
  run_cmd cp -r "$SCRIPT_DIR/bridges/kimaki" "$KIMAKI_CONFIG_DIR"
  run_cmd chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"

  if [ "$DRY_RUN" = true ]; then
    KIMAKI_BIN="/usr/bin/kimaki"
  else
    KIMAKI_BIN=$(_kimaki_resolve_service_bin "/usr/bin/kimaki")
  fi

  local KIMAKI_BIN_DIR NODE_BIN_DIR PATH_VALUE
  KIMAKI_BIN_DIR=$(dirname "$KIMAKI_BIN")
  NODE_BIN_DIR=$(_resolve_node_bin_dir "$KIMAKI_BIN")
  PATH_VALUE=$(_compose_path_value "$KIMAKI_BIN_DIR" "$NODE_BIN_DIR" /usr/local/bin /usr/bin /bin)
  _kimaki_assert_bin_identity "$KIMAKI_BIN" "$PATH_VALUE"
  local DATAMACHINE_WP_CMD
  DATAMACHINE_WP_CMD=$(_kimaki_datamachine_wp_cmd)

# Kimaki recreates a general-purpose #kimaki-<bot> channel, welcome message,
# and tutorial thread on every start. On a wp-coding-agents install the real
# project channel is the site channel, so the default is pure noise. Upstream
# added this opt-out in remorses/kimaki@7a9ab1e8 (fixes remorses/kimaki#175);
# it is inert on kimaki builds that predate it, so setting it unconditionally
# is safe and converges the moment the host upgrades.
  local ENV_BLOCK="Environment=HOME=$SERVICE_HOME
Environment=PATH=$PATH_VALUE
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR
Environment=DATAMACHINE_SITE_PATH=$SITE_PATH
Environment=DATAMACHINE_WP_CMD=$DATAMACHINE_WP_CMD
Environment=KIMAKI_NO_DEFAULT_CHANNEL=1"
  if [ -n "${AGENT_SLUG:-}" ]; then
    ENV_BLOCK="$ENV_BLOCK
Environment=DATAMACHINE_AGENT_SLUG=$AGENT_SLUG"
  fi
  if [ -n "$KIMAKI_BOT_TOKEN" ]; then
    ENV_BLOCK="$ENV_BLOCK
Environment=KIMAKI_BOT_TOKEN=$KIMAKI_BOT_TOKEN"
  fi
  if [ -n "${KIMAKI_LOCK_PORT:-}" ]; then
    ENV_BLOCK="$ENV_BLOCK
Environment=KIMAKI_LOCK_PORT=$KIMAKI_LOCK_PORT"
  fi
  if declare -F ai_gateway_enabled_for_opencode >/dev/null && ai_gateway_enabled_for_opencode; then
    ENV_BLOCK="$ENV_BLOCK
EnvironmentFile=-$(ai_gateway_env_file)"
  fi

  local unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  write_file "$unit_dir/$KIMAKI_UNIT" \
    "$(bridge_render_systemd "$KIMAKI_UNIT" "$ENV_BLOCK")"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable "$KIMAKI_UNIT"
}

# ============================================================================
# Upgrade-time config sync (Phase 2)
# ============================================================================

bridge_sync_config() {
  # Resolve paths per environment.
  #   VPS:   plugins live at /opt/kimaki-config/plugins (referenced by opencode.json,
  #          and by ExecStartPre in kimaki.service). Config dir holds plugins +
  #          post-upgrade.sh + skills-enable-list.txt.
  #   Local: opencode.json points at $KIMAKI_DATA_DIR/kimaki-config/plugins, the
  #          durable source that survives `npm update -g kimaki`. Existing configs
  #          that still reference package-local plugin paths are migrated by the
  #          opencode.json repair helper.
  local KIMAKI_CONFIG_DIR
  local KIMAKI_PLUGINS_DIR
  local BACKUP_DIR
  if [ "$LOCAL_MODE" = true ]; then
    KIMAKI_CONFIG_DIR="${KIMAKI_DATA_DIR}/kimaki-config"
    KIMAKI_PLUGINS_DIR="${KIMAKI_CONFIG_DIR}/plugins"
    BACKUP_DIR="${KIMAKI_DATA_DIR}/backups/kimaki-config.$TIMESTAMP"
    log "Phase 2: Syncing kimaki config (local mode)..."
    log "  Config dir:  $KIMAKI_CONFIG_DIR"
    log "  Plugins dir: $KIMAKI_PLUGINS_DIR (durable opencode target)"
  else
    KIMAKI_CONFIG_DIR="/opt/kimaki-config"
    KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
    if [ "$(id -u)" -eq 0 ]; then
      BACKUP_DIR="/opt/kimaki-config.backup.$TIMESTAMP"
    else
      BACKUP_DIR="${KIMAKI_DATA_DIR}/backups/kimaki-config.$TIMESTAMP"
    fi
    log "Phase 2: Syncing /opt/kimaki-config..."
  fi

  # Local opencode loads from the durable kimaki-config dir. Do not mirror these
  # plugins into the npm package; `npm update -g kimaki` wipes that directory and
  # the repair helper migrates older opencode.json files away from it.

  # VPS: if /opt/kimaki-config is missing, this install predates v0.4.0 (when
  # setup.sh started creating it). We're in the kimaki dispatch branch, so
  # kimaki IS the detected bridge and kimaki.service IS running — the
  # config dir just never got bootstrapped. Create it now from the repo.
  # All contents are wp-coding-agents-owned (plugins, post-upgrade.sh,
  # skill filters); there is no user state to preserve.
  if [ "$LOCAL_MODE" = false ] && [ ! -d "$KIMAKI_CONFIG_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would bootstrap $KIMAKI_CONFIG_DIR from $SCRIPT_DIR/bridges/kimaki/"
    else
      log "  $KIMAKI_CONFIG_DIR missing — bootstrapping from repo (install predates v0.4.0)"
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins"
      UPDATED_ITEMS+=("bootstrapped $KIMAKI_CONFIG_DIR (install predates v0.4.0)")
      # Fall through — the plugin/post-upgrade/skill-filter copy logic below
      # handles the actual file placement idempotently.
    fi
  fi

  # Backup current state (only if there's something to back up).
  if [ -d "$KIMAKI_CONFIG_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would backup $KIMAKI_CONFIG_DIR → $BACKUP_DIR"
    else
      mkdir -p "$(dirname "$BACKUP_DIR")"
      cp -r "$KIMAKI_CONFIG_DIR" "$BACKUP_DIR"
      log "  Backup created: $BACKUP_DIR"
    fi
  fi

  # Copy plugins to the durable target that opencode.json loads.
  local obsolete_notification_plugin="$KIMAKI_PLUGINS_DIR/homeboy-notification-context.ts"
  if [ -e "$obsolete_notification_plugin" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would remove obsolete $obsolete_notification_plugin"
    else
      rm -f "$obsolete_notification_plugin"
      log "  Removed obsolete $obsolete_notification_plugin"
      UPDATED_ITEMS+=("removed obsolete kimaki-config/plugins/homeboy-notification-context.ts")
    fi
  fi

  if [ -d "$SCRIPT_DIR/bridges/kimaki/plugins" ]; then
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$KIMAKI_CONFIG_DIR/plugins" 2>/dev/null || true
      mkdir -p "$KIMAKI_PLUGINS_DIR" 2>/dev/null || true
    fi
    for plugin_file in "$SCRIPT_DIR"/bridges/kimaki/plugins/*.ts; do
      [ -f "$plugin_file" ] || continue
      local name
      name=$(basename "$plugin_file")
      # Durable source of truth (and opencode.json target).
      if [ "$DRY_RUN" = true ]; then
        if ! cmp -s "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name" 2>/dev/null; then
          echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/plugins/$name"
        fi
      else
        if ! cmp -s "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name" 2>/dev/null; then
          cp "$plugin_file" "$KIMAKI_CONFIG_DIR/plugins/$name"
          log "  Updated $KIMAKI_CONFIG_DIR/plugins/$name (persistent source)"
          UPDATED_ITEMS+=("kimaki-config/plugins/$name")
        fi
      fi
    done
  fi

  # Stage post-upgrade.sh, launchd-start.sh, and skills-enable-list.txt in KIMAKI_CONFIG_DIR.
  # On VPS this is read by ExecStartPre. On local we execute it inline below.
  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$KIMAKI_CONFIG_DIR" 2>/dev/null || true
  fi

  if [ -f "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/post-upgrade.sh"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>/dev/null; then
        cp "$SCRIPT_DIR/bridges/kimaki/post-upgrade.sh" "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        chmod +x "$KIMAKI_CONFIG_DIR/post-upgrade.sh"
        log "  Updated $KIMAKI_CONFIG_DIR/post-upgrade.sh"
        UPDATED_ITEMS+=("kimaki-config/post-upgrade.sh")
      fi
    fi
  fi

  if [ -f "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" "$KIMAKI_CONFIG_DIR/launchd-start.sh" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/launchd-start.sh"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" "$KIMAKI_CONFIG_DIR/launchd-start.sh" 2>/dev/null; then
        cp "$SCRIPT_DIR/bridges/kimaki/launchd-start.sh" "$KIMAKI_CONFIG_DIR/launchd-start.sh"
        chmod +x "$KIMAKI_CONFIG_DIR/launchd-start.sh"
        log "  Updated $KIMAKI_CONFIG_DIR/launchd-start.sh"
        UPDATED_ITEMS+=("kimaki-config/launchd-start.sh")
      fi
    fi
  fi

  if [ -f "$SCRIPT_DIR/bridges/kimaki/restart-continuation.py" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/restart-continuation.py" "$KIMAKI_CONFIG_DIR/restart-continuation.py" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/restart-continuation.py"
      fi
    elif ! cmp -s "$SCRIPT_DIR/bridges/kimaki/restart-continuation.py" "$KIMAKI_CONFIG_DIR/restart-continuation.py" 2>/dev/null; then
      cp "$SCRIPT_DIR/bridges/kimaki/restart-continuation.py" "$KIMAKI_CONFIG_DIR/restart-continuation.py"
      chmod +x "$KIMAKI_CONFIG_DIR/restart-continuation.py"
      log "  Updated $KIMAKI_CONFIG_DIR/restart-continuation.py"
      UPDATED_ITEMS+=("kimaki-config/restart-continuation.py")
    fi
    if [ "$DRY_RUN" = false ]; then
      chmod +x "$KIMAKI_CONFIG_DIR/restart-continuation.py"
    fi
  fi

  if [ -f "$SCRIPT_DIR/bridges/kimaki/skills-enable-list.txt" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/skills-enable-list.txt" "$KIMAKI_CONFIG_DIR/skills-enable-list.txt" 2>/dev/null; then
        echo -e "${BLUE}[dry-run]${NC} Would update $KIMAKI_CONFIG_DIR/skills-enable-list.txt"
      fi
      if [ -e "$KIMAKI_CONFIG_DIR/skills-disable-list.txt" ]; then
        echo -e "${BLUE}[dry-run]${NC} Would remove obsolete $KIMAKI_CONFIG_DIR/skills-disable-list.txt"
      fi
    else
      if ! cmp -s "$SCRIPT_DIR/bridges/kimaki/skills-enable-list.txt" "$KIMAKI_CONFIG_DIR/skills-enable-list.txt" 2>/dev/null; then
        cp "$SCRIPT_DIR/bridges/kimaki/skills-enable-list.txt" "$KIMAKI_CONFIG_DIR/skills-enable-list.txt"
        log "  Updated $KIMAKI_CONFIG_DIR/skills-enable-list.txt"
        UPDATED_ITEMS+=("kimaki-config/skills-enable-list.txt")
      fi
      if [ -e "$KIMAKI_CONFIG_DIR/skills-disable-list.txt" ]; then
        rm -f "$KIMAKI_CONFIG_DIR/skills-disable-list.txt"
        log "  Removed obsolete $KIMAKI_CONFIG_DIR/skills-disable-list.txt"
        UPDATED_ITEMS+=("removed obsolete kimaki-config/skills-disable-list.txt")
      fi
    fi
  fi

  # Install wp-coding-agents' Kimaki bridge adapter binaries. They are intentionally
  # outside Kimaki's npm package so `npm update -g kimaki` cannot wipe them.
  _kimaki_sync_bin_helpers

# Resolve a runtime that can import the harness AND the TypeScript filter it
# loads. node cannot: dm-context-filter.ts is TypeScript, and node exits with
# ERR_UNKNOWN_FILE_EXTENSION on import. Echoes nothing when none is available,
# which the caller must treat as "unverified" rather than "failing".
#
# Checks PATH first, then the service home, then root's — a service-identity
# migration moves the toolchain, and bun installed for one identity is not on
# the PATH of a shell running as another.
_kimaki_effective_prompt_runner() {
  if command -v bun >/dev/null 2>&1; then
    command -v bun
    return 0
  fi
  # /root is checked because a service-identity migration leaves the toolchain
  # behind while the upgrade itself still runs as root — h44lacrosse.com's exact
  # shape. Overridable so a test can model a host with no bun anywhere.
  local home
  for home in "${SERVICE_HOME:-}" "$HOME" "${KIMAKI_BUN_FALLBACK_HOME:-/root}"; do
    [ -n "$home" ] || continue
    if [ -x "$home/.bun/bin/bun" ]; then
      printf '%s' "$home/.bun/bin/bun"
      return 0
    fi
  done
  return 0
}


  # On local, execute post-upgrade.sh inline to restore the upgrade skill.
  # On VPS, kimaki.service ExecStartPre runs it on next service restart.
  if [ "$LOCAL_MODE" = true ] && [ -x "$KIMAKI_CONFIG_DIR/post-upgrade.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would run: $KIMAKI_CONFIG_DIR/post-upgrade.sh"
    else
      log "  Running post-upgrade.sh to restore the upgrade skill..."
      if "$KIMAKI_CONFIG_DIR/post-upgrade.sh" 2>&1 | sed 's/^/    /'; then
        UPDATED_ITEMS+=("ran post-upgrade.sh (restored upgrade skill)")
      else
        warn "  post-upgrade.sh exited non-zero — review output above"
      fi
    fi
  fi

  # Run the effective-prompt regression test against the live kimaki install.
  #
  # This catches dm-context-filter regressions caused by kimaki upgrades that
  # reshuffle the system prompt (new sections, new code-fence patterns, new
  # banned phrases). Renders the prompt from the freshly-synced kimaki npm
  # package, runs dm-context-filter over it, asserts no banned phrases leak.
  #
  # Snapshot drift is a soft warning (the agent context is fine, the test
  # just needs `--update`). Leak failures are also surfaced as warnings,
  # not hard errors — upgrade.sh must not block on a test failure when the
  # underlying sync was successful. The signal is in UPDATED_ITEMS so the
  # final summary surfaces it.
  local TEST_SCRIPT="$SCRIPT_DIR/tests/effective-prompt/run.mjs"
  local TEST_RUNNER
  TEST_RUNNER="$(_kimaki_effective_prompt_runner)"
  if [ -f "$TEST_SCRIPT" ] && [ -z "$TEST_RUNNER" ]; then
    # NOT a leak. The harness imports dm-context-filter.ts directly, and node
    # cannot load TypeScript — it exits with ERR_UNKNOWN_FILE_EXTENSION before
    # rendering a single prompt. Reporting that as a possible leak is how this
    # warned on every upgrade of h44lacrosse.com while the filter was in fact
    # clean, which is worse than silence: an alarm that is always wrong teaches
    # everyone to scroll past the one time it is right.
    warn "  effective-prompt test SKIPPED — needs a TypeScript-capable runtime (bun)"
    warn "    the filter is UNVERIFIED on this host, not known to be leaking"
    UPDATED_ITEMS+=("effective-prompt test skipped — install bun to verify the prompt filter")
  elif [ -f "$TEST_SCRIPT" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would run: $TEST_RUNNER $TEST_SCRIPT"
    else
      log "  Running effective-prompt regression test ($TEST_RUNNER)..."
      local TEST_OUT
      if TEST_OUT=$("$TEST_RUNNER" "$TEST_SCRIPT" 2>&1); then
        # Pull the scenario count from the harness's "OK — N scenario(s)" line.
        local SCENARIO_LINE
        SCENARIO_LINE=$(echo "$TEST_OUT" | grep -E "^OK — [0-9]+ scenario" | head -1)
        log "  effective-prompt: PASS — ${SCENARIO_LINE:-no scenarios reported}"
        UPDATED_ITEMS+=("ran effective-prompt test (no filter leaks)")
      else
        warn "  effective-prompt test FAILED — dm-context-filter may be leaking banned phrases"
        warn "    rerun with: $TEST_RUNNER $TEST_SCRIPT --verbose"
        warn "    if drift is intentional: $TEST_RUNNER $TEST_SCRIPT --update"
        # Surface the failure section of the test output (last ~12 lines).
        echo "$TEST_OUT" | tail -12 | sed 's/^/    /' >&2
        UPDATED_ITEMS+=("effective-prompt test FAILED — review filter or refresh snapshots")
      fi
    fi
  fi

  # Refresh the CLI-channel registration so DMC's dispatch runtime uses native
  # kimaki instead of the removed adapter path.
  _kimaki_register_cli_channel

  # Refresh the worktree runtime-signature registration. Idempotent — only
  # touches disk when the env-var map drifts (e.g. a new subkey is added in
  # a future kimaki release).
  _kimaki_register_runtime_signature

  log "  Done."

  # Export resolved paths so print_summary can reference them
  RESOLVED_KIMAKI_CONFIG_DIR="$KIMAKI_CONFIG_DIR"
  RESOLVED_KIMAKI_PLUGINS_DIR="$KIMAKI_PLUGINS_DIR"
}

# ============================================================================
# Upgrade-time service refresh (Phase 5)
# ============================================================================

bridge_update_systemd() {
  log "Phase 5: Checking $KIMAKI_UNIT template..."

  local UNIT_FILE="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$KIMAKI_UNIT"
  [ -f "$UNIT_FILE" ] || { warn "  $UNIT_FILE does not exist — skipping"; return 0; }

  local CURRENT_ENV
  CURRENT_ENV=$(grep '^Environment=' "$UNIT_FILE" || true)
  if [ "${KIMAKI_DATA_DIR_EXPLICIT:-false}" = true ]; then
    CURRENT_ENV=$(_kimaki_remove_systemd_env_key "$CURRENT_ENV" KIMAKI_DATA_DIR)
  fi
  if [ "${KIMAKI_LOCK_PORT_EXPLICIT:-false}" = true ]; then
    CURRENT_ENV=$(_kimaki_remove_systemd_env_key "$CURRENT_ENV" KIMAKI_LOCK_PORT)
  fi
  if [ "${AGENT_SLUG_EXPLICIT:-false}" = true ]; then
    CURRENT_ENV=$(_kimaki_remove_systemd_env_key "$CURRENT_ENV" DATAMACHINE_AGENT_SLUG)
  fi

  local KIMAKI_BIN
  KIMAKI_BIN=$(_kimaki_resolve_service_bin "/usr/bin/kimaki")
  local KIMAKI_CONFIG_DIR="/opt/kimaki-config"
  local KIMAKI_BIN_DIR NODE_BIN_DIR PATH_VALUE
  KIMAKI_BIN_DIR=$(dirname "$KIMAKI_BIN")
  NODE_BIN_DIR=$(_resolve_node_bin_dir "$KIMAKI_BIN")
  PATH_VALUE=$(_compose_path_value "$KIMAKI_BIN_DIR" "$NODE_BIN_DIR" /usr/local/bin /usr/bin /bin)
  _kimaki_assert_bin_identity "$KIMAKI_BIN" "$PATH_VALUE"
  CURRENT_ENV=$(_ensure_systemd_path_contains "$CURRENT_ENV" "$KIMAKI_BIN_DIR")
  if [ -n "$NODE_BIN_DIR" ]; then
    CURRENT_ENV=$(_ensure_systemd_path_contains "$CURRENT_ENV" "$NODE_BIN_DIR")
  fi

  local TEMPLATE_ENV="Environment=HOME=$SERVICE_HOME
Environment=PATH=$PATH_VALUE
Environment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR
Environment=DATAMACHINE_SITE_PATH=$SITE_PATH
Environment=DATAMACHINE_WP_CMD=$(_kimaki_datamachine_wp_cmd)
Environment=KIMAKI_NO_DEFAULT_CHANNEL=1"
  if [ -n "${KIMAKI_LOCK_PORT:-}" ]; then
    TEMPLATE_ENV="$TEMPLATE_ENV
Environment=KIMAKI_LOCK_PORT=$KIMAKI_LOCK_PORT"
  fi
  if [ -n "${AGENT_SLUG:-}" ]; then
    TEMPLATE_ENV="$TEMPLATE_ENV
Environment=DATAMACHINE_AGENT_SLUG=$AGENT_SLUG"
  fi

  local MERGED_ENV
  MERGED_ENV=$(_merge_systemd_env_lines "$CURRENT_ENV" "$TEMPLATE_ENV")
  MERGED_ENV=$(_preserve_systemd_umask "$UNIT_FILE" "$MERGED_ENV")
  if declare -F ai_gateway_enabled_for_opencode >/dev/null && ai_gateway_enabled_for_opencode; then
    local gateway_env_line="EnvironmentFile=-$(ai_gateway_env_file)"
    if ! grep -qF "$gateway_env_line" "$UNIT_FILE" 2>/dev/null; then
      MERGED_ENV="$MERGED_ENV
$gateway_env_line"
    fi
  fi

  local NEW_UNIT
  NEW_UNIT=$(bridge_render_systemd "$KIMAKI_UNIT" "$MERGED_ENV")

  _smart_update_systemd_unit "$UNIT_FILE" "$NEW_UNIT" "$KIMAKI_UNIT"
}

bridge_update_launchd() {
  log "Phase 5a: Checking com.wp.kimaki launchd template..."

  local plist="$HOME/Library/LaunchAgents/com.wp.kimaki.plist"
  [ -f "$plist" ] || { warn "  $plist does not exist — skipping"; return 0; }

  local KIMAKI_BIN
  KIMAKI_BIN=$(_kimaki_resolve_service_bin "/opt/homebrew/bin/kimaki")

  local previous_token="${KIMAKI_BOT_TOKEN:-}"
  local token_was_set=false
  [ -n "${KIMAKI_BOT_TOKEN:-}" ] && token_was_set=true
  if [ -z "${KIMAKI_BOT_TOKEN:-}" ]; then
    KIMAKI_BOT_TOKEN=$(_plist_string_after_key "$plist" "KIMAKI_BOT_TOKEN" || true)
  fi

  local new_plist
  new_plist=$(bridge_render_launchd com.wp.kimaki)

  if [ "$token_was_set" = true ]; then
    KIMAKI_BOT_TOKEN="$previous_token"
  else
    unset KIMAKI_BOT_TOKEN
  fi

  if echo "$new_plist" | cmp -s - "$plist"; then
    log "  com.wp.kimaki.plist: unchanged"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would update $plist"
    echo -e "${BLUE}[dry-run]${NC} Diff:"
    diff -u "$plist" <(echo "$new_plist") 2>/dev/null | _redact_secret_diff | head -30 | sed 's/^/    /' || true
    return 0
  fi

  cp "$plist" "${plist}.backup.$TIMESTAMP"
  echo "$new_plist" > "$plist"
  log "  Updated $plist (backup: ${plist}.backup.$TIMESTAMP)"
  log "  Diff:"
  diff -u "${plist}.backup.$TIMESTAMP" "$plist" 2>/dev/null | _redact_secret_diff | head -30 | sed 's/^/    /' || true
  log "  NOTE: com.wp.kimaki NOT restarted — run the restart command in the summary when ready"
  UPDATED_ITEMS+=("com.wp.kimaki.plist (not restarted)")
}

# ============================================================================
# Templates: systemd unit + launchd plist
# ============================================================================

bridge_render_systemd() {
  local unit="$1" env_block="$2"
  local normalized_unit
  normalized_unit=$(_kimaki_normalize_unit_name "$unit")
  [ "$normalized_unit" = "$unit" ] || { echo "kimaki has no unit '$unit'" >&2; return 1; }
  local skill_filter_args
  skill_filter_args="$(_kimaki_skill_filter_args_shell)"
  _kimaki_validate_lock_port

  # The lock port reaches the unit through Environment= rather than the
  # --lock-port argument this used to append (#334). That moved a guarantee the
  # RENDERER held unconditionally into data the CALLER supplies, so a caller
  # that passes an env block without the line silently drops the port and the
  # instance falls back to the default — two instances then fight over one lock.
  # Re-assert it here, where it was always enforced.
  if [ -n "${KIMAKI_LOCK_PORT:-}" ] && \
     ! printf '%s\n' "$env_block" | grep -q '^Environment=KIMAKI_LOCK_PORT='; then
    env_block="$env_block
Environment=KIMAKI_LOCK_PORT=$KIMAKI_LOCK_PORT"
  fi

  local stale_worker_cleanup="# User-wide stale-worker cleanup omitted for instance isolation."
  if [ "$unit" = "kimaki.service" ]; then
    stale_worker_cleanup='ExecStartPre=-/usr/bin/pkill -TERM -u '$SERVICE_USER' -f "opencode-ai/bin/.*serve"'
  fi
  cat <<EOF
[Unit]
Description=Kimaki Discord Bot (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
# Reap stray opencode-serve children left behind by the previous kimaki
# process before starting a fresh one. Each kimaki session spawns its own
# opencode-serve worker; if kimaki exits uncleanly (crash, OOM, manual
# kill) those workers are reparented to PID 1 and keep running. They all
# share \$HOME/.local/share/opencode/auth.json, so concurrent OAuth
# refreshes race each other — Anthropic rotates the refresh token on every
# use, and the loser of the race gets HTTP 400 invalid_grant on its next
# request. \`pkill -u $SERVICE_USER\` scopes the kill to this service's
# user so multi-tenant hosts aren't sniped. The \`-\` prefix makes systemd
# tolerate exit code 1 (no matches found, the happy path on a clean box).
$stale_worker_cleanup
ExecStartPre=$KIMAKI_CONFIG_DIR/post-upgrade.sh
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique$skill_filter_args
ExecStartPost=$KIMAKI_CONFIG_DIR/restart-continuation.py consume --site-path $SITE_PATH --data-dir $KIMAKI_DATA_DIR --kimaki-bin $KIMAKI_BIN
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

bridge_render_launchd() {
  local label="$1"
  [ "$label" = "com.wp.kimaki" ] || { echo "kimaki has no label '$label'" >&2; return 1; }
  local kimaki_bin_dir node_bin_dir path_value
  kimaki_bin_dir="$(dirname "$KIMAKI_BIN")"
  node_bin_dir="$(_resolve_node_bin_dir "$KIMAKI_BIN")"
  path_value="$(_compose_path_value "$HOME/.local/bin" "$kimaki_bin_dir" "$node_bin_dir" "$HOME/.opencode/bin" "$HOME/.bun/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)"
  local skill_filter_plist_args
  skill_filter_plist_args="$(_kimaki_skill_filter_args_plist)"
  local launchd_start
  launchd_start="${KIMAKI_DATA_DIR}/kimaki-config/launchd-start.sh"
  local datamachine_wp_cmd
  datamachine_wp_cmd=$(_kimaki_datamachine_wp_cmd)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$launchd_start</string>
        <string>$KIMAKI_BIN</string>
        <string>--data-dir</string>
        <string>$KIMAKI_DATA_DIR</string>
        <string>--auto-restart</string>
        <string>--no-critique</string>
$skill_filter_plist_args
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$KIMAKI_DATA_DIR/kimaki.log</string>
    <key>StandardErrorPath</key>
    <string>$KIMAKI_DATA_DIR/kimaki.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$path_value</string>
        <key>KIMAKI_DATA_DIR</key>
        <string>$KIMAKI_DATA_DIR</string>
        <key>KIMAKI_CONFIG_DIR</key>
        <string>${KIMAKI_DATA_DIR}/kimaki-config</string>
        <key>DATAMACHINE_SITE_PATH</key>
        <string>$SITE_PATH</string>
        <key>DATAMACHINE_WP_CMD</key>
        <string>$datamachine_wp_cmd</string>
        <key>KIMAKI_NO_DEFAULT_CHANNEL</key>
        <string>1</string>$(if [ -n "${AGENT_SLUG:-}" ]; then echo "
        <key>DATAMACHINE_AGENT_SLUG</key>
        <string>$AGENT_SLUG</string>"; fi)$(if [ -n "${KIMAKI_BOT_TOKEN:-}" ]; then echo "
        <key>KIMAKI_BOT_TOKEN</key>
        <string>$KIMAKI_BOT_TOKEN</string>"; fi)$(_kimaki_ai_gateway_launchd_env_xml)
    </dict>
</dict>
</plist>
EOF
}

_kimaki_datamachine_wp_cmd() {
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    external_wordpress_control_command
    return 0
  fi
  if [ "${IS_STUDIO:-false}" = true ]; then
    printf '%s\n' "studio wp"
    return 0
  fi

  printf '%s\n' "${WP_CMD:-wp}"
}

_kimaki_skill_filter_mode() {
  if [ -n "${KIMAKI_SKILL_ENABLES_FILE:-}" ] \
    || { [ -n "${KIMAKI_CONFIG_DIR:-}" ] && [ -f "$KIMAKI_CONFIG_DIR/skills-enable-list.txt" ]; } \
    || { [ -n "${KIMAKI_DATA_DIR:-}" ] && [ -f "$KIMAKI_DATA_DIR/kimaki-config/skills-enable-list.txt" ]; } \
    || [ -f "$SCRIPT_DIR/bridges/kimaki/skills-enable-list.txt" ]; then
    printf '%s\n' "enable"
    return 0
  fi

  printf '%s\n' "disable"
}

_kimaki_ai_gateway_launchd_env_xml() {
  declare -F ai_gateway_enabled_for_opencode >/dev/null || return 0
  ai_gateway_enabled_for_opencode || return 0
  declare -F ai_gateway_read_env_value >/dev/null || return 0

  local env_file base_url api_key
  env_file="$(ai_gateway_env_file)"
  base_url="$(ai_gateway_read_env_value OPENAI_BASE_URL "$env_file")"
  api_key="$(ai_gateway_read_env_value OPENAI_API_KEY "$env_file")"
  [ -n "$base_url" ] || base_url="$(ai_gateway_base_url)"

  echo "
        <key>OPENAI_BASE_URL</key>
        <string>$base_url</string>"
  if [ -n "$api_key" ]; then
    echo "        <key>OPENAI_API_KEY</key>
        <string>$api_key</string>"
  fi
}

_kimaki_skill_filter_source() {
  if [ "$(_kimaki_skill_filter_mode)" = "enable" ]; then
    if [ -n "${KIMAKI_SKILL_ENABLES_FILE:-}" ]; then
      printf '%s\n' "$KIMAKI_SKILL_ENABLES_FILE"
    elif [ -n "${KIMAKI_CONFIG_DIR:-}" ] && [ -f "$KIMAKI_CONFIG_DIR/skills-enable-list.txt" ]; then
      printf '%s\n' "$KIMAKI_CONFIG_DIR/skills-enable-list.txt"
    elif [ -n "${KIMAKI_DATA_DIR:-}" ] && [ -f "$KIMAKI_DATA_DIR/kimaki-config/skills-enable-list.txt" ]; then
      printf '%s\n' "$KIMAKI_DATA_DIR/kimaki-config/skills-enable-list.txt"
    else
      printf '%s\n' "$SCRIPT_DIR/bridges/kimaki/skills-enable-list.txt"
    fi
    return 0
  fi

  if [ -n "${KIMAKI_SKILL_FILTERS_FILE:-}" ]; then
    printf '%s\n' "$KIMAKI_SKILL_FILTERS_FILE"
  elif [ -n "${KIMAKI_CONFIG_DIR:-}" ] && [ -f "$KIMAKI_CONFIG_DIR/skills-disable-list.txt" ]; then
    printf '%s\n' "$KIMAKI_CONFIG_DIR/skills-disable-list.txt"
  elif [ -n "${KIMAKI_DATA_DIR:-}" ] && [ -f "$KIMAKI_DATA_DIR/kimaki-config/skills-disable-list.txt" ]; then
    printf '%s\n' "$KIMAKI_DATA_DIR/kimaki-config/skills-disable-list.txt"
  else
    printf '%s\n' ""
  fi
}

_kimaki_each_filtered_skill() {
  local filters_file skill
  filters_file="$(_kimaki_skill_filter_source)"
  [ -f "$filters_file" ] || return 0

  while IFS= read -r skill || [ -n "$skill" ]; do
    [ -n "$skill" ] || continue
    case "$skill" in \#*) continue ;; esac
    printf '%s\n' "$skill"
  done < "$filters_file"
}

_kimaki_skill_filter_args_shell() {
  local out="" skill flag
  if [ "$(_kimaki_skill_filter_mode)" = "enable" ]; then
    flag="--enable-skill"
  else
    flag="--disable-skill"
  fi
  while IFS= read -r skill; do
    out="$out $flag $skill"
  done < <(_kimaki_each_filtered_skill)
  printf '%s' "$out"
}

_kimaki_skill_filter_args_plist() {
  local out="" skill flag
  if [ "$(_kimaki_skill_filter_mode)" = "enable" ]; then
    flag="--enable-skill"
  else
    flag="--disable-skill"
  fi
  while IFS= read -r skill; do
    out="$out        <string>$flag</string>
        <string>$skill</string>
"
  done < <(_kimaki_each_filtered_skill)
  printf '%s' "$out"
}

# ============================================================================
# Human-facing command accessors
# ============================================================================

bridge_restart_cmd() {
  local env="$1" helper target site data_dir
  site=$(_kimaki_shell_quote "$SITE_PATH")
  data_dir=$(_kimaki_shell_quote "$KIMAKI_DATA_DIR")
  case "$env" in
    local-launchd)
      helper=$(_kimaki_shell_quote "$KIMAKI_DATA_DIR/kimaki-config/restart-continuation.py")
      target=$(_kimaki_shell_quote "$HOME/Library/LaunchAgents/com.wp.kimaki.plist")
      echo "$helper restart --mode launchd --target $target --site-path $site --data-dir $data_dir"
      ;;
    local-manual)
      echo "cd $SITE_PATH && kimaki"
      ;;
    vps)
      helper=$(_kimaki_shell_quote "${RESOLVED_KIMAKI_CONFIG_DIR:-/opt/kimaki-config}/restart-continuation.py")
      target=$(_kimaki_shell_quote "${KIMAKI_UNIT:-kimaki.service}")
      echo "$helper restart --mode systemd --target $target --site-path $site --data-dir $data_dir"
      ;;
    *)
      echo "bridge_restart_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_verify_cmd() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd) echo "launchctl print gui/${uid}/com.wp.kimaki | head -20" ;;
    local-manual)  echo "pgrep -fl kimaki" ;;
    vps)           echo "systemctl status ${KIMAKI_UNIT:-kimaki.service}" ;;
    *)
      echo "bridge_verify_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_logs_cmd() {
  echo "tail -f $KIMAKI_DATA_DIR/kimaki.log"
}

bridge_start_hint() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd) echo "launchctl kickstart gui/${uid}/com.wp.kimaki" ;;
    local-manual)  bridge_restart_cmd local-manual ;;
    vps)           echo "systemctl start ${KIMAKI_UNIT:-kimaki.service}" ;;
    *)
      echo "bridge_start_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_stop_hint() {
  local env="$1" uid
  uid=$(id -u)
  case "$env" in
    local-launchd) echo "launchctl kill SIGTERM gui/${uid}/com.wp.kimaki" ;;
    vps)           echo "systemctl stop ${KIMAKI_UNIT:-kimaki.service}" ;;
    local-manual)  ;;
    *)
      echo "bridge_stop_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

# ============================================================================
# Summary blocks (lib/summary.sh next-steps prose)
# ============================================================================

# Onboarding prose for VPS when KIMAKI_BOT_TOKEN is missing.
bridge_vps_setup_block() {
  echo "  1. Set up Discord bot token:"
  echo "     Option A: Run kimaki interactively first (sets up database)"
  if [ "$RUN_AS_ROOT" = false ]; then
    echo "       su - $SERVICE_USER -c 'cd $SITE_PATH && kimaki'"
  else
    echo "       cd $SITE_PATH && kimaki"
  fi
  echo "     Option B: Set KIMAKI_BOT_TOKEN in the systemd service"
  echo "       systemctl edit ${KIMAKI_UNIT:-kimaki.service}"
  echo "       [Service]"
  echo "       Environment=KIMAKI_BOT_TOKEN=your-token-here"
  echo ""
  echo "  2. Start the agent:  systemctl start ${KIMAKI_UNIT:-kimaki.service}"
}

# Onboarding prose for macOS launchd when KIMAKI_BOT_TOKEN is missing.
bridge_launchd_setup_block() {
  local uid
  uid=$(id -u)
  echo "  Kimaki setup:"
  echo "    1. Run onboarding:  cd $SITE_PATH && kimaki"
  echo "    2. Enable service:  launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/com.wp.kimaki.plist"
}

# Optional preamble for VPS start-block when creds ARE configured.
bridge_vps_start_preamble() {
  echo "  Bot token configured via KIMAKI_BOT_TOKEN."
}

# Verify-block addendum printed by upgrade.sh after the standard status line.
bridge_verify_extra() {
  local PLUGINS_DIR="${RESOLVED_KIMAKI_PLUGINS_DIR:-/opt/kimaki-config/plugins}"
  echo "test -f $PLUGINS_DIR/dm-context-filter.ts && test -f $PLUGINS_DIR/dm-agent-sync.ts   # managed OpenCode plugins installed"
  echo "command -v kimaki >/dev/null   # native Kimaki binary available"
}
