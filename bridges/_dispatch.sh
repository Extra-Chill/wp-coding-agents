#!/bin/bash
# bridges/_dispatch.sh — auto-discovery + dispatch for bridges/*.sh.
#
# Mirrors runtimes/*.sh: each bridges/<name>.sh defines a self-contained
# unit that owns install, config sync, systemd/launchd templates, summary
# blocks, and any per-bridge assets at bridges/<name>/. Adding a new bridge
# is "drop a file (and optionally a dir) in bridges/" — no edits to lib/,
# upgrade.sh, summary.sh, or this file.
#
# Hook contract (all functions namespaced bridge_<hook> inside each file):
#
#   Mandatory:
#     bridge_install            — install + service register (LOCAL_MODE +
#                                 PLATFORM branch internally)
#     bridge_systemd_units      — space-sep list of systemd unit filenames
#     bridge_launchd_labels     — space-sep list of launchd plist labels
#     bridge_binaries           — space-sep list of binaries on PATH;
#                                 first is the primary (drives detection)
#     bridge_display_name       — lowercase prose name for mid-sentence
#     bridge_display_title      — capitalised name for headers
#     bridge_render_systemd <unit-name> <env-block>
#     bridge_render_launchd <label>
#     bridge_sync_config        — upgrade-time, idempotent
#     bridge_update_systemd     — VPS upgrade-time unit refresh
#     bridge_restart_cmd <env>  — env: local-launchd | local-manual | vps
#     bridge_verify_cmd <env>
#     bridge_logs_cmd
#     bridge_start_hint <env>
#     bridge_stop_hint <env>
#     bridge_is_ready           — return 0 when the bridge has its credentials
#
#   Optional:
#     bridge_update_launchd     — local launchd refresh (mac launchd-using
#                                 bridges only; defaults to no-op)
#     bridge_vps_setup_block    — onboarding prose for missing VPS creds
#     bridge_launchd_setup_block — onboarding prose for missing local creds
#     bridge_vps_start_preamble — prose printed before "systemctl start ..."
#                                 when VPS creds are configured
#
# All hooks run inside a subshell that sources the bridge file fresh, so
# bridge_<hook> definitions never leak between bridges. Subshell isolation
# also means a bridge file is free to define helpers (`_my_helper`) without
# colliding with other bridges or with lib/.
#
# Caller contract — bridge files expect the same per-install globals the
# legacy lib/chat-bridge.sh / lib/chat-bridges.sh did (SERVICE_USER,
# SERVICE_HOME, SITE_PATH, KIMAKI_BIN, KIMAKI_DATA_DIR, CC_BIN, CC_DATA_DIR,
# OPENCODE_BIN, TELEGRAM_BIN, etc.). Subshell exports them automatically; no
# extra wiring needed.

# Resolve the bridges/ directory once. SCRIPT_DIR is the wp-coding-agents
# install root (set by setup.sh / upgrade.sh / tests/*); when this file is
# sourced standalone (e.g. from a test), fall back to its own dirname.
if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR/bridges" ]; then
  BRIDGES_DIR="$SCRIPT_DIR/bridges"
else
  BRIDGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ===========================================================================
# Shared helpers — used by every bridge's render / install / update path.
# Kept on the dispatcher (not copy-pasted into every bridge file) so future
# bridges inherit them for free.
# ===========================================================================

# _resolve_node_bin_dir [<kimaki-bin-hint>]
#
# Prints the directory containing `node` to stdout, or empty if none found.
# launchd inherits a minimal PATH, so plugins shelling out via `#!/usr/bin/env
# node` need the node bin dir baked into the rendered plist. nvm users
# install node under ~/.nvm/versions/node/<v>/bin/, which neither homebrew nor
# /usr/local/bin/ cover — that gap is the bug this helper closes (#73).
#
# Resolution order:
#   1. `command -v node` in the renderer's interactive shell.
#   2. The node baked into the kimaki shim itself (parses `exec '<node>' …`
#      from the shim's first non-shebang line).
#   3. Empty — caller falls back to its existing PATH and warns.
_resolve_node_bin_dir() {
  local kimaki_hint="${1:-}"
  local node_path=""

  if command -v node >/dev/null 2>&1; then
    node_path="$(command -v node)"
  elif [ -n "$kimaki_hint" ] && [ -f "$kimaki_hint" ]; then
    # Shim looks like:
    #   #!/bin/sh
    #   exec '/path/to/node' '--flag' … '/path/to/kimaki.js' "$@"
    # Walk space-separated tokens on the `exec` line and pick the first
    # single-quoted absolute path ending in /node. Pure bash so the helper
    # works under launchd / minimal-PATH contexts where coreutils may be
    # absent — only the shell's own builtins (read, case, IFS) are used.
    local exec_line token stripped
    while IFS= read -r exec_line; do
      case "$exec_line" in
        exec\ *)
          # shellcheck disable=SC2086
          set -- $exec_line
          shift  # drop leading "exec"
          for token in "$@"; do
            stripped="${token#\'}"
            stripped="${stripped%\'}"
            case "$stripped" in
              */node)
                node_path="$stripped"
                break
                ;;
            esac
          done
          break
          ;;
      esac
    done < "$kimaki_hint"
  fi

  [ -n "$node_path" ] || return 0
  [ -x "$node_path" ] || return 0
  # Pure bash dirname so the helper works in minimal-PATH contexts.
  local dir="${node_path%/*}"
  [ -n "$dir" ] || dir="/"
  printf '%s' "$dir"
}

# _compose_path_value <dir1> [<dir2> …]
#
# Joins directories into a colon-separated PATH value, dropping duplicates and
# empties while preserving the first-occurrence order. Used by the launchd
# renderer so prepending the node bin dir doesn't shadow homebrew/system paths
# or generate `dir::dir` strings when the kimaki and node bins live in the
# same directory (the pre-PR-#73 npm-global world).
_compose_path_value() {
  local seen="" out="" dir
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    case ":$seen:" in
      *":$dir:"*) continue ;;
    esac
    seen="$seen:$dir"
    if [ -z "$out" ]; then
      out="$dir"
    else
      out="$out:$dir"
    fi
  done
  printf '%s' "$out"
}

# _merge_systemd_env_lines <current_env> <template_env>
#
# Merge new Environment= lines from a template into the current unit,
# preserving every existing Environment= line the host has customised (e.g.
# BUN_INSTALL, custom PATH, secrets) and appending template keys that are
# missing. Returns the merged block on stdout.
_merge_systemd_env_lines() {
  local current_env="$1"
  local template_env="$2"

  # Drop existing values that point into a service home the install has just
  # migrated away from.
  #
  # This merge keeps the INSTALLED unit's value for any key the template also
  # sets — deliberately, so operator edits survive an upgrade. But the service
  # identity migration (#93) changes User= and the home every identity-derived
  # value is built from, and those values are not operator edits: they describe
  # an identity that no longer exists.
  #
  # Measured on h44lacrosse.com: the migration produced User=opencode alongside
  # Environment=HOME=/root and KIMAKI_DATA_DIR=/root/.kimaki. Starting that unit
  # runs the agent as a user that cannot read either path — /root is 0700 — so
  # it comes up with no session database and no runtime state. The same defect
  # #204 fixed from the other direction: there the User flipped silently while
  # the state stayed put; here the User moved and the environment stayed put.
  #
  # Filtering by VALUE rather than by a list of key names is what makes this
  # hold. PATH on a long-lived install carries /root/.kimaki/bin,
  # /root/.cargo/bin and /root/.bun/bin; BUN_INSTALL points at /root/.bun.
  # Enumerating keys would have fixed HOME and KIMAKI_DATA_DIR and left the
  # agent with a PATH full of directories it can no longer read (#318: prefer
  # the property over a list of names).
  if [ -n "${SERVICE_MIGRATION_PREVIOUS_HOME:-}" ]; then
    current_env="$(printf '%s\n' "$current_env" \
      | grep -vF "=${SERVICE_MIGRATION_PREVIOUS_HOME}" \
      | grep -vF ":${SERVICE_MIGRATION_PREVIOUS_HOME}" || true)"
  fi

  local merged="$current_env"
  while IFS= read -r tmpl_line; do
    [ -z "$tmpl_line" ] && continue
    local key
    key=$(echo "$tmpl_line" | sed -n 's/^Environment=\([^=]*\)=.*/\1/p')
    [ -z "$key" ] && continue
    if ! echo "$current_env" | grep -q "^Environment=${key}="; then
      if [ -n "$merged" ]; then
        merged="$merged
$tmpl_line"
      else
        merged="$tmpl_line"
      fi
    fi
  done <<< "$template_env"
  echo "$merged"
}

# _ensure_systemd_path_contains <current_env> <required_dir>
#
# Prepend <required_dir> to the existing Environment=PATH= line if it's
# missing. Returns the (possibly updated) env block on stdout. No-op when
# PATH= is absent or already contains the directory.
_ensure_systemd_path_contains() {
  local current_env="$1" required_dir="$2"
  if ! echo "$current_env" | grep -q '^Environment=PATH='; then
    echo "$current_env"
    return 0
  fi
  if echo "$current_env" | grep '^Environment=PATH=' | grep -F -q "$required_dir"; then
    echo "$current_env"
    return 0
  fi

  awk -v dir="$required_dir" '
    /^Environment=PATH=/ && ! done {
      sub(/^Environment=PATH=/, "Environment=PATH=" dir ":")
      done = 1
    }
    { print }
  ' <<< "$current_env"
}

# _systemd_unit_user <unit_file>
#
# Print the User= value from an existing systemd unit. Empty output +
# return 1 when the file is missing or has no User= directive.
_systemd_unit_user() {
  local unit_file="$1"
  [ -f "$unit_file" ] || return 1
  local user
  user=$(sed -n 's/^User=\(.*\)$/\1/p' "$unit_file" | head -1)
  [ -n "$user" ] || return 1
  printf '%s' "$user"
}

# _preserve_systemd_umask <unit_file> <env_block>
#
# Carry the existing unit's UMask= directive into a re-rendered unit.
# The bridge templates do not render UMask, but non-root installs rely on
# it (e.g. UMask=0002 for group-write with www-data). Without this, every
# Phase 5 refresh silently dropped the directive. Appends the existing
# UMask= line to the env block (both land in [Service]); no-op when the
# existing unit has none.
_preserve_systemd_umask() {
  local unit_file="$1" env_block="$2"
  local umask_line=""
  if [ -f "$unit_file" ]; then
    umask_line=$(grep '^UMask=' "$unit_file" | head -1 || true)
  fi
  if [ -z "$umask_line" ]; then
    printf '%s' "$env_block"
    return 0
  fi
  if [ -n "$env_block" ]; then
    printf '%s\n%s' "$env_block" "$umask_line"
  else
    printf '%s' "$umask_line"
  fi
}

# adopt_service_identity_from_units
#
# On upgrade, the EXISTING installed unit is the source of truth for the
# service identity — not the script's default. upgrade.sh historically
# hardcoded RUN_AS_ROOT=true, so on a non-root install (User=opencode)
# Phase 5 re-rendered the unit with User=root: a silent service-identity
# flip that creates root-owned state files, breaks the next non-root
# start, and re-introduces the root-homed-path trap (#198/#93). See #204.
#
# Walks the loaded bridge's systemd units, reads User= from the first one
# that exists, and re-derives SERVICE_USER / SERVICE_HOME /
# KIMAKI_DATA_DIR / RUN_AS_ROOT to match. Skipped in local mode (no
# systemd), when no bridge is loaded, or when the operator forced an
# identity explicitly via --root / --non-root (SERVICE_USER_FORCED=true).
#
# SYSTEMD_UNIT_DIR is overridable for tests (defaults to
# /etc/systemd/system).
adopt_service_identity_from_units() {
  [ "${LOCAL_MODE:-false}" = true ] && return 0
  [ "${SERVICE_USER_FORCED:-false}" = true ] && return 0
  local unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local unit unit_user unit_home
  local units=""
  if declare -F bridge_systemd_units >/dev/null 2>&1; then
    units="$(bridge_systemd_units)"
  fi
  if declare -F datamachine_worker_systemd_units >/dev/null 2>&1; then
    units="$units $(datamachine_worker_systemd_units)"
  fi
  for unit in $units; do
    [ -f "$unit_dir/$unit" ] || continue
    unit_user=$(_systemd_unit_user "$unit_dir/$unit") || continue

    if [ "$unit_user" != "$SERVICE_USER" ]; then
      unit_home=$(getent passwd "$unit_user" 2>/dev/null | cut -d: -f6)
      if [ -z "$unit_home" ]; then
        if [ "$unit_user" = "root" ]; then
          unit_home="/root"
        else
          unit_home="/home/$unit_user"
        fi
      fi
      log "  Adopting service identity from $unit: User=$unit_user (script default was $SERVICE_USER)"
      SERVICE_USER="$unit_user"
      SERVICE_HOME="$unit_home"
      if [ "${KIMAKI_DATA_DIR_EXPLICIT:-false}" != true ]; then
        KIMAKI_DATA_DIR="$unit_home/.kimaki"
      fi
      if [ "$unit_user" = "root" ]; then
        RUN_AS_ROOT=true
      else
        RUN_AS_ROOT=false
      fi
    fi
    return 0
  done
  return 0
}

# Redact secret-looking values before printing generated unit/plist diffs.
# Dry-run output is operator-facing and often pasted into chats or PRs.
_redact_secret_diff() {
  awk '
    /<key>[^<]*(TOKEN|SECRET|PASSWORD|API_KEY|REFRESH_TOKEN)[^<]*<\/key>/ {
      print
      redact_next_string = 1
      next
    }
    redact_next_string && /<string>.*<\/string>/ {
      sub(/<string>.*<\/string>/, "<string><redacted></string>")
      print
      redact_next_string = 0
      next
    }
    /^[-+ ]Environment=[^=]*(TOKEN|SECRET|PASSWORD|API_KEY|REFRESH_TOKEN)=/ {
      sub(/=.*/, "=<redacted>")
      print
      next
    }
    /^[-+ ](OPENAI_API_KEY|KIMAKI_BOT_TOKEN|TELEGRAM_BOT_TOKEN|CC_CONNECT_TOKEN)=/ {
      sub(/=.*/, "=<redacted>")
      print
      next
    }
    { print }
  '
}

# _report_systemd_unit_health <unit> [<label>]
#
# Read and report the runtime state of one systemd unit. Reporting only —
# this never starts, stops, or restarts anything, preserving the operator
# boundary that _smart_update_systemd_unit documents.
#
# Reconciling the unit *file* while staying silent about the unit's runtime
# state let a managed unit sit in `failed` for four weeks while every
# upgrade reported success (#576). A desired-state reconciler that reports
# only the half of the state it writes is not reporting state.
#
# Warnings are recorded in HEALTH_WARNINGS so the caller can resurface them
# in the final summary, where they cannot scroll past.
_report_systemd_unit_health() {
  local unit="$1"
  local label="${2:-$unit}"

  command -v systemctl >/dev/null 2>&1 || return 0

  local active enabled since
  active="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  [ -n "$active" ] || return 0
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"

  case "$active" in
    active)
      log "  $label: active"
      ;;
    failed)
      since="$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
      warn "  $label: FAILED${since:+ since $since} — this upgrade did not start it"
      warn "  $label: inspect with 'systemctl status $unit' and 'journalctl -u $unit -n 50'"
      # NOTE: `[ -n "${arr+x}" ]` reads an EMPTY bash array as unset, which
      # would drop the first warning every time. Test declaration instead.
      if declare -p HEALTH_WARNINGS >/dev/null 2>&1; then
        HEALTH_WARNINGS+=("$label is in state 'failed' — systemctl status $unit")
      fi
      ;;
    *)
      # An enabled unit that is not running is a real finding. A disabled
      # one is a deliberate operator choice and stays quiet.
      if [ "$enabled" = "enabled" ]; then
        warn "  $label: $active while enabled — this upgrade did not start it"
        warn "  $label: start with 'systemctl start $unit'"
        if declare -p HEALTH_WARNINGS >/dev/null 2>&1; then
          HEALTH_WARNINGS+=("$label is enabled but '$active' — systemctl start $unit")
        fi
      else
        log "  $label: $active (not enabled)"
      fi
      ;;
  esac
}

# _smart_update_systemd_unit <unit_file> <new_unit> [<label>]
#
# Diff + write + daemon-reload a single systemd unit. Records the change in
# the caller's UPDATED_ITEMS array. NEVER restarts the unit — operator does
# that explicitly per the documented restart hint in the summary.
#
# Unit health is reported on every pass, including the unchanged and
# dry-run paths: a long-dead unit whose file is already correct is the
# quietest failure of all (#576).
_smart_update_systemd_unit() {
  local unit_file="$1"
  local new_unit="$2"
  local label="${3:-$(basename "$unit_file")}"

  if [ ! -f "$unit_file" ]; then
    warn "  $unit_file does not exist — skipping"
    return 0
  fi

  _report_systemd_unit_health "$(basename "$unit_file")" "$label"

  if echo "$new_unit" | cmp -s - "$unit_file"; then
    log "  $(basename "$unit_file"): unchanged"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would update $unit_file"
    echo -e "${BLUE}[dry-run]${NC} Diff:"
    diff -u "$unit_file" <(echo "$new_unit") 2>/dev/null | _redact_secret_diff | head -30 | sed 's/^/    /' || true
    echo -e "${BLUE}[dry-run]${NC} Would run: systemctl daemon-reload"
    return 0
  fi

  cp "$unit_file" "${unit_file}.backup.$TIMESTAMP"
  echo "$new_unit" > "$unit_file"
  log "  Updated $unit_file (backup: ${unit_file}.backup.$TIMESTAMP)"
  log "  Diff:"
  diff -u "${unit_file}.backup.$TIMESTAMP" "$unit_file" 2>/dev/null | _redact_secret_diff | head -30 | sed 's/^/    /' || true
  systemctl daemon-reload
  log "  systemctl daemon-reload complete"
  log "  NOTE: $label NOT restarted — run the restart command in the summary when ready"
  UPDATED_ITEMS+=("$label (daemon-reloaded, not restarted)")
}

# _plist_string_after_key <plist_path> <key>
#
# Extract the <string>VALUE</string> immediately after a given <key>NAME</key>
# in a launchd plist. Used by bridges that need to preserve a token already
# baked into an existing plist when re-rendering.
_plist_string_after_key() {
  local plist="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "<key>" key "</key>" { found = 1; next }
    found && /<string>/ { print; exit }
  ' "$plist" | sed 's/.*<string>\(.*\)<\/string>.*/\1/'
}

# bridge_names — list every discoverable bridge, one per line.
# Discovery: any bridges/*.sh whose basename does not start with `_` is a
# bridge. Underscore prefix marks dispatcher / shared infrastructure files.
bridge_names() {
  local f name
  for f in "$BRIDGES_DIR"/*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"
    case "$name" in
      _*) continue ;;
    esac
    echo "$name"
  done
}

# bridge_file <name> — absolute path to the bridge file, or empty if missing.
bridge_file() {
  local name="$1"
  local f="$BRIDGES_DIR/${name}.sh"
  [ -f "$f" ] || return 1
  printf '%s' "$f"
}

# bridge_load <name>
#
# Source bridges/<name>.sh INTO THE CURRENT SHELL. Defines bridge_install,
# bridge_render_systemd, bridge_render_launchd, bridge_sync_config, etc. for
# direct invocation. Use after CHAT_BRIDGE is decided so subsequent calls
# (install, render, summary) can mutate parent state (KIMAKI_BIN,
# RESOLVED_KIMAKI_PLUGINS_DIR, UPDATED_ITEMS, etc.) the same way the legacy
# code did.
#
# Mirrors the runtimes/<name>.sh model: load once, call hooks directly.
# Returns 1 if the bridge file is missing.
bridge_load() {
  local name="$1"
  local f
  f="$(bridge_file "$name")" || {
    echo "bridge_load: unknown bridge '$name'" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "$f"
}

# bridge_call <name> <hook> [args...]
#
# Read-only registry walk: source bridges/<name>.sh in a SUBSHELL and invoke
# `bridge_<hook>`. Stdout passes through; the subshell prevents the bridge's
# function definitions from clobbering the currently-loaded active bridge.
#
# Use for detection, multi-bridge metadata queries, or any case where you
# need to consult a bridge OTHER than the active CHAT_BRIDGE without
# disturbing it. For the active bridge, prefer bridge_load + direct call.
#
# Returns 1 if the bridge file is missing, 2 if the hook is undefined.
bridge_call() {
  local name="$1" hook="$2"
  shift 2
  local f
  f="$(bridge_file "$name")" || {
    echo "bridge_call: unknown bridge '$name'" >&2
    return 1
  }
  (
    # shellcheck disable=SC1090
    source "$f"
    if ! declare -F "bridge_${hook}" >/dev/null; then
      echo "bridge_call: '$name' does not implement hook 'bridge_${hook}'" >&2
      exit 2
    fi
    "bridge_${hook}" "$@"
  )
}

# bridge_has_hook [<name>] <hook> — return 0 if hook is defined.
#
# One-arg form: check the currently loaded bridge (calls declare -F directly).
# Two-arg form: spawn a subshell to source <name> and check there.
bridge_has_hook() {
  if [ "$#" -eq 1 ]; then
    declare -F "bridge_$1" >/dev/null
    return $?
  fi
  local name="$1" hook="$2"
  local f
  f="$(bridge_file "$name")" || return 1
  (
    # shellcheck disable=SC1090
    source "$f"
    declare -F "bridge_${hook}" >/dev/null
  )
}

# Detection priority. The legacy lib/chat-bridges.sh::bridge_names hardcoded
# the order "kimaki cc-connect telegram"; the same order is preserved here so
# detection tie-breaks are unchanged for hosts that somehow have multiple
# bridges installed (rare, since the install paths are mutually exclusive).
# Bridges not listed here fall to alphabetical filesystem order after the
# known ones — this is the auto-discovery extension point.
BRIDGE_DETECTION_ORDER="kimaki cc-connect telegram"

# bridge_names_for_detection — emit known bridges in priority order, then any
# unknown ones in alphabetical order. Both groups are filtered to bridges
# that actually exist on disk.
bridge_names_for_detection() {
  local known unknown name f seen
  seen=""
  for name in $BRIDGE_DETECTION_ORDER; do
    f="$BRIDGES_DIR/${name}.sh"
    if [ -f "$f" ]; then
      echo "$name"
      seen="$seen $name "
    fi
  done
  for name in $(bridge_names); do
    case " $seen " in
      *" $name "*) continue ;;
    esac
    echo "$name"
  done
}

# bridge_detect_local — print the first locally-installed bridge name.
#
# A bridge counts as "present" if ANY of its launchd plists exist OR ANY of
# its binaries are on PATH. Probe order is BRIDGE_DETECTION_ORDER, then
# alphabetical for any bridge files added without updating that list.
bridge_detect_local() {
  local bridge label bin
  for bridge in $(bridge_names_for_detection); do
    for label in $(bridge_call "$bridge" launchd_labels 2>/dev/null); do
      if [ -f "$HOME/Library/LaunchAgents/${label}.plist" ]; then
        echo "$bridge"
        return 0
      fi
    done
    for bin in $(bridge_call "$bridge" binaries 2>/dev/null); do
      if command -v "$bin" >/dev/null 2>&1; then
        echo "$bridge"
        return 0
      fi
    done
  done
  return 0
}

# bridge_detect_vps — print the first bridge with installed systemd units.
bridge_detect_vps() {
  local bridge unit unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  for bridge in $(bridge_names_for_detection); do
    for unit in $(bridge_call "$bridge" systemd_units 2>/dev/null); do
      if [ -f "$unit_dir/${unit}" ]; then
        echo "$bridge"
        return 0
      fi
    done
    if [ "$bridge" = "kimaki" ]; then
      for unit in "$unit_dir"/kimaki*.service; do
        if [ -f "$unit" ]; then
          echo "$bridge"
          return 0
        fi
      done
    fi
  done
  return 0
}

# install_chat_bridge — setup-time entrypoint, dispatched from setup.sh.
# Honours --no-chat (INSTALL_CHAT=false) and unknown-bridge guarding.
# Loads the active bridge into the parent shell so the install hook can
# mutate state (KIMAKI_BIN, KIMAKI_PLIST, etc.) the rest of setup.sh reads.
install_chat_bridge() {
  if [ "$INSTALL_CHAT" != true ]; then
    log "Phase 9: Skipping chat bridge (--no-chat)"
    return
  fi

  log "Phase 9: Installing chat bridge ($CHAT_BRIDGE)..."

  if ! bridge_file "$CHAT_BRIDGE" >/dev/null 2>&1; then
    warn "Unknown chat bridge: $CHAT_BRIDGE"
    warn "Supported bridges: $(bridge_names | tr '\n' ' ')"
    warn "Skipping chat bridge installation"
    return
  fi

  bridge_load "$CHAT_BRIDGE"
  bridge_install
}
