#!/bin/bash
# bridges/roadie.sh — Roadie Discord bridge, the only chat bridge.
#
# Roadie (https://github.com/Extra-Chill/roadie) is the host-agnostic
# chat-to-agent bridge that replaced Kimaki. The host supplies configuration;
# Roadie owns the behavior Kimaki needed outside-in workarounds for:
#
#   Kimaki workaround                         Roadie
#   ----------------------------------------  ----------------------------------
#   pkill stale opencode serve (ExecStartPre)  orphan cleanup on start
#   restart-continuation.py (ExecStartPost)    resumes interrupted runs itself
#   post-upgrade.sh prompt patch + skill pass  ROADIE_PROMPT_CONFIG, host skills
#   self-upgrade suppression                   ROADIE_MANAGED=1
#   sudoers dispatch wrapper                   send token + POST /roadie/send
#   seed-kimaki-credential.mjs                 ROADIE_BOT_TOKEN_FILE
#
# Install layout:
#   VPS:   Roadie package  /usr/local/lib/wp-coding-agents/roadie  (root-owned,
#                          world-readable so www-data can run `roadie send`)
#          Config          /opt/roadie-config/{plugins,prompt-config.yaml}
#          Secrets         /etc/wp-coding-agents/roadie<suffix>/{bot-token,send-token}
#          Unit            /etc/systemd/system/roadie[-<name>].service
#   Local: npm global install of the pinned tarball; config under
#          $ROADIE_DATA_DIR/roadie-config; launchd plist com.wp.roadie on macOS.
#
# The release is pinned in bridges/roadie/roadie-version; the host owns
# upgrades (ROADIE_MANAGED=1), so Roadie never upgrades itself.

ROADIE_RELEASE_URL_TEMPLATE='https://github.com/Extra-Chill/roadie/releases/download/v%s/extrachill-roadie-%s.tgz'
ROADIE_PACKAGE_NAME='@extrachill/roadie'

# ============================================================================
# Identity
# ============================================================================

bridge_systemd_units()  { echo "${ROADIE_UNIT:-roadie.service}"; }
bridge_launchd_labels() { echo "com.wp.roadie"; }
# Kimaki units this bridge migrates from; read for service identity only.
bridge_legacy_systemd_units() { echo "kimaki$(_roadie_instance_suffix).service"; }
bridge_binaries()       { echo "roadie"; }
bridge_display_name()   { echo "roadie"; }
bridge_display_title()  { echo "Roadie"; }

# Ready when Roadie can authenticate: a token from setup, a token file, or
# saved credentials in an existing data dir (onboarding or a Kimaki migration).
bridge_is_ready() {
  [ -n "${ROADIE_BOT_TOKEN:-}" ] && return 0
  [ -s "$(_roadie_bot_token_file)" ] 2>/dev/null && return 0
  [ -n "${ROADIE_DATA_DIR:-}" ] && [ -s "$ROADIE_DATA_DIR/discord-sessions.db" ]
}

roadie_pinned_version() {
  local file="$SCRIPT_DIR/bridges/roadie/roadie-version" version
  version="$(tr -d '[:space:]' < "$file" 2>/dev/null || true)"
  [ -n "$version" ] || error "Roadie release pin is missing: $file"
  printf '%s\n' "$version"
}

roadie_release_url() {
  local version
  version="$(roadie_pinned_version)"
  # shellcheck disable=SC2059
  printf "$ROADIE_RELEASE_URL_TEMPLATE\n" "$version" "$version"
}

_roadie_unit_env_value() {
  local unit_file="$1" key="$2"
  sed -n "s/^Environment=${key}=//p" "$unit_file" | head -1
}

_roadie_validate_lock_port() {
  [ -z "${ROADIE_LOCK_PORT:-}" ] && return 0
  case "$ROADIE_LOCK_PORT" in *[!0-9]*) error "Invalid Roadie lock port '$ROADIE_LOCK_PORT'" ;; esac
  if [ "$ROADIE_LOCK_PORT" -lt 1 ] || [ "$ROADIE_LOCK_PORT" -gt 65535 ]; then
    error "Invalid Roadie lock port '$ROADIE_LOCK_PORT' (expected 1-65535)"
  fi
}

_roadie_normalize_unit_name() {
  local unit="$1" stem
  [ -n "$unit" ] || error "Invalid Roadie unit: name cannot be empty"
  case "$unit" in
    *.service) ;;
    *) unit="$unit.service" ;;
  esac
  case "$unit" in
    */*|*\\*|*..*|*[!A-Za-z0-9_.@-]*)
      error "Invalid Roadie unit '$unit' (expected a traversal-safe unit basename)"
      ;;
  esac
  stem="${unit%.service}"
  case "$stem" in
    roadie|roadie-?*) ;;
    *) error "Invalid Roadie unit '$unit' (expected roadie.service or roadie-<name>.service)" ;;
  esac
  printf '%s\n' "$unit"
}

_roadie_remove_systemd_env_key() {
  local env_block="$1" key="$2"
  printf '%s\n' "$env_block" | grep -v "^Environment=${key}=" || true
}

_roadie_unit_dir() {
  printf '%s\n' "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
}

# Select an installed Roadie instance by exact WordPress WorkingDirectory.
# Explicit inputs win; otherwise zero matches keeps the default only when no
# Roadie unit exists, one match is adopted, and ambiguity is fatal.
_roadie_resolve_instance() {
  local unit_dir
  unit_dir="$(_roadie_unit_dir)"
  ROADIE_UNIT=$(_roadie_normalize_unit_name "${ROADIE_UNIT:-roadie.service}")

  local unit working normalized_site="$SITE_PATH" matches=() installed=()
  if [ -d "$SITE_PATH" ]; then
    normalized_site=$(cd "$SITE_PATH" 2>/dev/null && pwd -P || printf '%s' "$SITE_PATH")
  fi

  if [ "${ROADIE_UNIT_EXPLICIT:-false}" != true ]; then
    for unit in "$unit_dir"/roadie*.service; do
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
      ROADIE_UNIT=$(basename "${matches[0]}")
      log "  Selected $ROADIE_UNIT for WorkingDirectory=$SITE_PATH"
    elif [ ${#matches[@]} -gt 1 ]; then
      error "Multiple Roadie units target $SITE_PATH: ${matches[*]}. Pass --roadie-unit <unit>."
    elif [ ${#installed[@]} -gt 0 ]; then
      error "No Roadie unit targets $SITE_PATH. Pass --roadie-unit <unit> to select or create one. Installed: ${installed[*]}"
    fi
  fi

  local unit_file="$unit_dir/$ROADIE_UNIT"
  if [ ! -f "$unit_file" ]; then
    _roadie_validate_lock_port
    return 0
  fi

  local value unit_user unit_home
  unit_user=$(_systemd_unit_user "$unit_file" || true)
  unit_home=$(_roadie_unit_env_value "$unit_file" HOME)
  if [ "${SERVICE_USER_FORCED:-false}" != true ] && [ -n "$unit_user" ]; then
    SERVICE_USER="$unit_user"
    [ -n "$unit_home" ] || unit_home=$(getent passwd "$unit_user" 2>/dev/null | cut -d: -f6)
    [ -n "$unit_home" ] || { [ "$unit_user" = root ] && unit_home=/root || unit_home="/home/$unit_user"; }
    SERVICE_HOME="$unit_home"
    [ "$unit_user" = root ] && RUN_AS_ROOT=true || RUN_AS_ROOT=false
  fi

  if [ "${ROADIE_DATA_DIR_EXPLICIT:-false}" != true ]; then
    value=$(_roadie_unit_env_value "$unit_file" ROADIE_DATA_DIR)
    ROADIE_DATA_DIR="${value:-$SERVICE_HOME/.roadie}"
  fi
  if [ "${ROADIE_LOCK_PORT_EXPLICIT:-false}" != true ]; then
    ROADIE_LOCK_PORT=$(_roadie_unit_env_value "$unit_file" ROADIE_LOCK_PORT)
  fi
  if [ -z "${AGENT_SLUG:-}" ]; then
    AGENT_SLUG=$(_roadie_unit_env_value "$unit_file" DATAMACHINE_AGENT_SLUG)
  fi
  _roadie_validate_lock_port
}

_roadie_instance_suffix() {
  local unit="${ROADIE_UNIT:-roadie.service}"
  [ "$unit" = "roadie.service" ] && return 0
  unit="${unit%.service}"
  unit="${unit#roadie-}"
  printf -- '-%s' "$unit"
}

_roadie_effective_uid() {
  printf '%s\n' "${WP_CODING_AGENTS_TEST_EUID:-$(id -u)}"
}

_roadie_shell_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

# The `--roadie-only` re-run that repairs any root-owned Roadie artifact.
_roadie_root_repair_command() {
  local command
  printf -v command 'sudo -- %q --roadie-only --wp-path %q --roadie-unit %q' \
    "$SCRIPT_DIR/upgrade.sh" "$SITE_PATH" "${ROADIE_UNIT:-roadie.service}"
  printf '%s\n' "$command"
}

# ============================================================================
# Package (pinned release tarball)
# ============================================================================

_roadie_uses_system_prefix() {
  [ "${LOCAL_MODE:-false}" != true ]
}

# Root-owned and world-readable: the service user runs it, and www-data runs
# `roadie send` from the dispatch transport without any sudo hop.
_roadie_system_prefix() {
  printf '%s\n' "${ROADIE_SYSTEM_PREFIX:-/usr/local/lib/wp-coding-agents/roadie}"
}

_roadie_installed_version() {
  local package_json
  if _roadie_uses_system_prefix; then
    package_json="$(_roadie_system_prefix)/lib/node_modules/$ROADIE_PACKAGE_NAME/package.json"
  else
    package_json="$(npm root -g 2>/dev/null)/$ROADIE_PACKAGE_NAME/package.json"
  fi
  [ -f "$package_json" ] || return 0
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$package_json" 2>/dev/null || true
}

_roadie_provision_package() {
  local want have url prefix
  want="$(roadie_pinned_version)"
  have="$(_roadie_installed_version)"
  if [ "$have" = "$want" ] && [ "${DRY_RUN:-false}" != true ]; then
    log "Roadie $want already installed"
    return 0
  fi
  url="$(roadie_release_url)"

  if ! _roadie_uses_system_prefix; then
    run_cmd npm install -g "$url"
    return 0
  fi

  prefix="$(_roadie_system_prefix)"
  if [ "$(_roadie_effective_uid)" -ne 0 ] && [ "${DRY_RUN:-false}" != true ]; then
    warn "  Roadie ${have:-(not installed)} needs $want; installing into $prefix requires root."
    warn "  Root repair required: $(_roadie_root_repair_command)"
    PENDING_ITEMS+=("Roadie $want install (root)")
    return 0
  fi
  run_cmd mkdir -p "$prefix"
  run_cmd npm install -g --prefix "$prefix" "$url"
  if [ "${DRY_RUN:-false}" != true ]; then
    chmod -R a+rX "$prefix"
    log "Roadie ${have:+$have → }$want installed in $prefix"
    UPDATED_ITEMS+=("Roadie $want")
  fi
}

roadie_bin() {
  if _roadie_uses_system_prefix; then
    printf '%s/bin/roadie\n' "$(_roadie_system_prefix)"
    return 0
  fi
  command -v roadie 2>/dev/null || printf '%s\n' roadie
}

# ============================================================================
# Secrets (bot token, send token)
# ============================================================================

_roadie_secrets_dir() {
  if [ "${LOCAL_MODE:-false}" = true ]; then
    printf '%s/secrets\n' "${ROADIE_DATA_DIR:-$HOME/.roadie}"
  else
    printf '%s/roadie%s\n' "${ROADIE_SECRETS_ROOT:-/etc/wp-coding-agents}" "$(_roadie_instance_suffix)"
  fi
}

_roadie_bot_token_file()  { printf '%s/bot-token\n' "$(_roadie_secrets_dir)"; }
_roadie_send_token_file() { printf '%s/send-token\n' "$(_roadie_secrets_dir)"; }

# The send token reaches only POST /roadie/send on the loopback lock port.
# Group-readable by the web user so scheduled dispatch can `roadie send`
# without sudo; anyone who can read it can prompt the agent, so treat that
# group like shell access.
_roadie_dispatch_group() {
  printf '%s\n' "${ROADIE_DISPATCH_GROUP:-www-data}"
}

_roadie_write_secret() {
  local file="$1" value="$2" owner="$3" group="$4" mode="$5"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write $file ($mode $owner:$group)"
    return 0
  fi
  local tmp="$file.tmp.$$"
  ( umask 077 && printf '%s\n' "$value" > "$tmp" )
  chown "$owner:$group" "$tmp" 2>/dev/null || true
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
}

_roadie_install_secrets() {
  local dir bot_file send_file owner group dispatch_group
  dir="$(_roadie_secrets_dir)"
  bot_file="$(_roadie_bot_token_file)"
  send_file="$(_roadie_send_token_file)"
  owner="${SERVICE_USER:-$(id -un)}"
  group="$(id -gn "$owner" 2>/dev/null || echo "$owner")"
  dispatch_group="$(_roadie_dispatch_group)"

  if [ "${LOCAL_MODE:-false}" != true ] && [ "$(_roadie_effective_uid)" -ne 0 ] && [ "${DRY_RUN:-false}" != true ]; then
    if [ -s "$send_file" ] || [ -r "$send_file" ]; then
      return 0
    fi
    warn "  Roadie secrets in $dir need root."
    warn "  Root repair required: $(_roadie_root_repair_command)"
    PENDING_ITEMS+=("Roadie secrets (root)")
    return 0
  fi

  run_cmd mkdir -p "$dir"
  [ "${DRY_RUN:-false}" = true ] || chmod 0755 "$dir"

  if [ -n "${ROADIE_BOT_TOKEN:-}" ]; then
    _roadie_write_secret "$bot_file" "$ROADIE_BOT_TOKEN" "$owner" "$group" 0600
  fi

  if [ ! -s "$send_file" ]; then
    local token
    token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    if [ "${LOCAL_MODE:-false}" = true ] || ! getent group "$dispatch_group" >/dev/null 2>&1; then
      _roadie_write_secret "$send_file" "$token" "$owner" "$group" 0600
    else
      _roadie_write_secret "$send_file" "$token" "$owner" "$dispatch_group" 0640
    fi
    UPDATED_ITEMS+=("Roadie send token")
  fi
}

# ============================================================================
# Config (managed plugins + prompt config)
# ============================================================================

roadie_config_dir() {
  if [ "${LOCAL_MODE:-false}" = true ]; then
    printf '%s/roadie-config\n' "${ROADIE_DATA_DIR:-$HOME/.roadie}"
  else
    printf '%s\n' "${ROADIE_CONFIG_DIR:-/opt/roadie-config}"
  fi
}

bridge_managed_plugins_dir() {
  printf '%s/plugins\n' "$(roadie_config_dir)"
}

# Roadie plugins (ROADIE_PLUGINS), as opposed to the OpenCode plugins above.
roadie_plugins_dir() {
  printf '%s/roadie-plugins\n' "$(roadie_config_dir)"
}

roadie_plugins_value() {
  printf '%s/host-upgrade.mjs\n' "$(roadie_plugins_dir)"
}

roadie_prompt_config_file() {
  printf '%s/prompt-config.yaml\n' "$(roadie_config_dir)"
}

# Copy the wp-coding-agents-owned assets (OpenCode plugins, Roadie prompt
# config) into the durable config dir. Idempotent; reports what changed.
_roadie_sync_assets() {
  local config_dir plugins_dir src
  config_dir="$(roadie_config_dir)"
  plugins_dir="$(bridge_managed_plugins_dir)"

  if declare -F agent_state_ownership_can_maintain >/dev/null && \
     [ -d "$config_dir" ] && ! agent_state_ownership_can_maintain "$config_dir"; then
    warn "  Skipping: $config_dir is not maintainable by $(id -un) (see agent-state root repair)"
    PENDING_ITEMS+=("roadie-config sync (root-owned $config_dir)")
    return 0
  fi

  run_cmd mkdir -p "$plugins_dir"

  run_cmd mkdir -p "$(roadie_plugins_dir)"
  for src in "$SCRIPT_DIR"/bridges/roadie/plugins/*.ts "$SCRIPT_DIR/bridges/roadie/prompt-config.yaml" \
             "$SCRIPT_DIR/bridges/roadie/accounts.mjs" "$SCRIPT_DIR"/bridges/roadie/roadie-plugins/*.mjs; do
    [ -f "$src" ] || continue
    local name dest
    name="$(basename "$src")"
    case "$src" in
      */roadie-plugins/*) dest="$(roadie_plugins_dir)/$name" ;;
      *.ts) dest="$plugins_dir/$name" ;;
      *)    dest="$config_dir/$name" ;;
    esac
    if cmp -s "$src" "$dest" 2>/dev/null; then
      continue
    fi
    if [ "${DRY_RUN:-false}" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would update $dest"
      continue
    fi
    cp "$src" "$dest"
    log "  Updated $dest"
    UPDATED_ITEMS+=("roadie-config/${dest#"$config_dir"/}")
  done
}

# ============================================================================
# Kimaki → Roadie migration (one-shot, existing installs)
# ============================================================================

# Migrates a Kimaki install to Roadie on the same host, in place:
#   1. stop the Kimaki unit/plist
#   2. SQLite online backup of discord-sessions.db into the Roadie data dir
#      (a plain copy can catch the WAL mid-write); copy the remaining state
#   3. carry KIMAKI_BOT_TOKEN / KIMAKI_LOCK_PORT / DATAMACHINE_* over
#   4. move the subscription accounts (OpenCode's rotation pools) into
#      subrouter, which Roadie routes through. Only while Kimaki is stopped:
#      refresh tokens rotate on use, so two live copies invalidate each other.
#   5. route model choices on those providers through subrouter: one preset
#      per model in use (exactly that model; fallbacks are operator policy),
#      in the Roadie database copy and opencode.json
#   6. disable the Kimaki unit, keep it and ~/.kimaki untouched as rollback
# Roadie's own schema migrations run on first start. Idempotent: a Roadie data
# dir that already holds a database is never overwritten.
_roadie_kimaki_unit() {
  local unit_dir unit="${KIMAKI_UNIT:-}"
  unit_dir="$(_roadie_unit_dir)"
  if [ -z "$unit" ]; then
    local suffix
    suffix="$(_roadie_instance_suffix)"
    unit="kimaki${suffix}.service"
  fi
  [ -f "$unit_dir/$unit" ] && printf '%s\n' "$unit"
}

# The installed Roadie package; its bundled @subrouter/cli owns the account store.
roadie_package_dir() {
  if _roadie_uses_system_prefix; then
    printf '%s/lib/node_modules/%s\n' "$(_roadie_system_prefix)" "$ROADIE_PACKAGE_NAME"
  else
    printf '%s/%s\n' "$(npm root -g 2>/dev/null)" "$ROADIE_PACKAGE_NAME"
  fi
}

# OpenCode's data dir for the service user (auth.json and the account pools).
_roadie_opencode_data_dir() {
  if [ "${LOCAL_MODE:-false}" = true ]; then
    printf '%s/opencode\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
  else
    printf '%s/.local/share/opencode\n' "$SERVICE_HOME"
  fi
}

# Run bridges/roadie/accounts.mjs as the service user, so subrouter's store is
# created under (and owned by) the service home. The script goes over stdin:
# the wp-coding-agents checkout need not be readable by the service user.
_roadie_accounts() {
  local mode="$1" node_bin
  node_bin="$(command -v node 2>/dev/null)" || { warn "  node not found; cannot move accounts"; return 1; }
  local args=("$mode" --opencode-data "$(_roadie_opencode_data_dir)" --roadie-package "$(roadie_package_dir)")
  if [ "$mode" = import ] && [ -n "${ROADIE_SUBROUTER_PRESETS_JSON:-}" ]; then
    args+=(--presets-json "$ROADIE_SUBROUTER_PRESETS_JSON")
  fi
  if [ "${LOCAL_MODE:-false}" != true ] && [ -n "${SERVICE_USER:-}" ] && [ "$(id -un)" != "$SERVICE_USER" ]; then
    sudo -n -H -u "$SERVICE_USER" env HOME="$SERVICE_HOME" "$node_bin" --input-type=module - "${args[@]}" \
      < "$SCRIPT_DIR/bridges/roadie/accounts.mjs"
  else
    "$node_bin" --input-type=module - "${args[@]}" < "$SCRIPT_DIR/bridges/roadie/accounts.mjs"
  fi
}

# Printed after a migration: the rollback's account step, using the installed
# copy of accounts.mjs.
roadie_accounts_rollback_command() {
  local user_prefix=""
  if [ "${LOCAL_MODE:-false}" != true ] && [ -n "${SERVICE_USER:-}" ]; then
    user_prefix="sudo -u $SERVICE_USER -H "
  fi
  printf '%snode %s/accounts.mjs export --opencode-data %s --roadie-package %s\n' \
    "$user_prefix" "$(roadie_config_dir)" "$(_roadie_opencode_data_dir)" "$(roadie_package_dir)"
}

# A failed migration must not leave the host without a bridge: restart the
# Kimaki service it stopped.
_roadie_restore_kimaki() {
  local unit="$1"
  if [ -n "$unit" ]; then
    systemctl start "$unit" 2>/dev/null || true
  elif [ "${PLATFORM:-}" = mac ]; then
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.wp.kimaki.plist" 2>/dev/null || true
  fi
}

roadie_migrate_from_kimaki() {
  local unit_dir kimaki_unit unit_file kimaki_data
  unit_dir="$(_roadie_unit_dir)"

  if [ "${LOCAL_MODE:-false}" = true ]; then
    kimaki_data="${KIMAKI_DATA_DIR:-$HOME/.kimaki}"
    local kimaki_plist="$HOME/Library/LaunchAgents/com.wp.kimaki.plist"
    if [ -f "$kimaki_plist" ]; then
      [ -n "${ROADIE_BOT_TOKEN:-}" ] || ROADIE_BOT_TOKEN="$(_plist_string_after_key "$kimaki_plist" KIMAKI_BOT_TOKEN || true)"
      if [ -z "${ROADIE_LOCK_PORT:-}" ]; then
        local plist_port
        plist_port="$(_plist_string_after_key "$kimaki_plist" KIMAKI_LOCK_PORT || true)"
        [ -z "$plist_port" ] || ROADIE_LOCK_PORT="$plist_port"
      fi
    fi
  else
    kimaki_unit="$(_roadie_kimaki_unit || true)"
    [ -n "$kimaki_unit" ] || return 0
    unit_file="$unit_dir/$kimaki_unit"
    kimaki_data="$(_roadie_unit_env_value "$unit_file" KIMAKI_DATA_DIR)"
    [ -n "$kimaki_data" ] || kimaki_data="$SERVICE_HOME/.kimaki"

    local value
    [ -n "${ROADIE_BOT_TOKEN:-}" ] || ROADIE_BOT_TOKEN="$(_roadie_unit_env_value "$unit_file" KIMAKI_BOT_TOKEN)"
    if [ -z "${ROADIE_LOCK_PORT:-}" ]; then
      value="$(_roadie_unit_env_value "$unit_file" KIMAKI_LOCK_PORT)"
      # Pre-#334 Kimaki units passed the port as an ExecStart argument.
      [ -n "$value" ] || value="$(sed -n 's/^ExecStart=.*--lock-port[= ]\([0-9][0-9]*\).*/\1/p' "$unit_file" | head -1)"
      [ -z "$value" ] || ROADIE_LOCK_PORT="$value"
    fi
    [ -n "${AGENT_SLUG:-}" ] || AGENT_SLUG="$(_roadie_unit_env_value "$unit_file" DATAMACHINE_AGENT_SLUG)"
  fi

  local source_db="$kimaki_data/discord-sessions.db"
  local target_db="$ROADIE_DATA_DIR/discord-sessions.db"
  [ -f "$source_db" ] || return 0
  if [ -f "$target_db" ]; then
    log "  Roadie data already present at $ROADIE_DATA_DIR; Kimaki state not copied"
    return 0
  fi

  log "Migrating Kimaki → Roadie: $kimaki_data → $ROADIE_DATA_DIR"
  if [ "${DRY_RUN:-false}" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would stop ${kimaki_unit:-the Kimaki service}, back up $source_db, copy state, move accounts into subrouter, disable Kimaki"
    return 0
  fi

  if [ -n "${kimaki_unit:-}" ]; then
    systemctl stop "$kimaki_unit" 2>/dev/null || true
  elif [ "${PLATFORM:-}" = mac ]; then
    launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.wp.kimaki.plist" 2>/dev/null || true
  fi

  mkdir -p "$ROADIE_DATA_DIR"
  if ! sqlite3 -readonly "$source_db" ".backup '$target_db'"; then
    rm -f "$target_db"
    _roadie_restore_kimaki "${kimaki_unit:-}"
    error "SQLite backup of $source_db failed; Kimaki state left untouched and Kimaki restarted"
  fi
  if [ "$(sqlite3 "$target_db" 'PRAGMA integrity_check;' 2>/dev/null | head -1)" != ok ]; then
    rm -f "$target_db"
    _roadie_restore_kimaki "${kimaki_unit:-}"
    error "Migrated database failed integrity_check; Kimaki state left untouched and Kimaki restarted"
  fi

  local entry
  for entry in attachments session-system session-system-pinned projects; do
    [ -e "$kimaki_data/$entry" ] || continue
    cp -a "$kimaki_data/$entry" "$ROADIE_DATA_DIR/"
  done

  # Accounts, and a subrouter preset for each direct model the stored choices
  # use (derived from them, no routing policy). Without them Roadie cannot
  # reach a model, so a failure rolls the whole migration back.
  local accounts_out models_out
  if ! ROADIE_SUBROUTER_PRESETS_JSON="$(python3 "$SCRIPT_DIR/bridges/roadie/repoint-models.py" presets \
         --db "$target_db" --opencode-json "$SITE_PATH/opencode.json" 2>&1)"; then
    printf '%s\n' "$ROADIE_SUBROUTER_PRESETS_JSON" >&2
    rm -f "$target_db"
    _roadie_restore_kimaki "${kimaki_unit:-}"
    error "Reading stored model choices failed; Kimaki state left untouched and Kimaki restarted"
  fi
  if ! accounts_out="$(_roadie_accounts import 2>&1)"; then
    printf '%s\n' "$accounts_out" >&2
    rm -f "$target_db"
    _roadie_restore_kimaki "${kimaki_unit:-}"
    error "Moving subscription accounts into subrouter failed; Kimaki state left untouched and Kimaki restarted"
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] && log "  subrouter $entry"
  done <<< "$accounts_out"

  # Point those choices at the presets, in the Roadie copy of the database
  # (before Roadie first starts) and opencode.json.
  if ! models_out="$(python3 "$SCRIPT_DIR/bridges/roadie/repoint-models.py" apply \
         --db "$target_db" --opencode-json "$SITE_PATH/opencode.json" 2>&1)"; then
    printf '%s\n' "$models_out" >&2
    rm -f "$target_db"
    _roadie_restore_kimaki "${kimaki_unit:-}"
    error "Moving model choices to subrouter presets failed; Kimaki state left untouched and Kimaki restarted"
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] && log "  $entry"
  done <<< "$models_out"

  if [ -n "${SERVICE_USER:-}" ] && [ "$(_roadie_effective_uid)" -eq 0 ]; then
    chown -R "$SERVICE_USER:$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")" "$ROADIE_DATA_DIR"
  fi

  if [ -n "${kimaki_unit:-}" ]; then
    systemctl disable "$kimaki_unit" 2>/dev/null || true
    log "  Disabled $kimaki_unit (kept as rollback with $kimaki_data)"
  fi
  UPDATED_ITEMS+=("migrated Kimaki → Roadie ($kimaki_data kept as rollback)")
  UPDATED_ITEMS+=("subscription accounts moved into subrouter; on rollback, first run: $(roadie_accounts_rollback_command)")
  UPDATED_ITEMS+=("model choices routed through subrouter presets; add fallbacks with `subrouter preset` (opencode.json backed up as opencode.json.before-subrouter-*; restore it on rollback)")
}

# ============================================================================
# Install (setup-time)
# ============================================================================

bridge_install() {
  _roadie_provision_package
  ROADIE_BIN="$(roadie_bin)"
  roadie_migrate_from_kimaki
  _roadie_install_secrets
  _roadie_sync_assets

  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    log "External WordPress profile: Roadie installed. Start it from the runtime environment with:"
    log "  WP_CONTROL_TRANSPORT_JSON='<argv-json>' $(external_wordpress_bridge_command)"
  elif [ "$LOCAL_MODE" = true ] && [ "$PLATFORM" = "mac" ]; then
    _roadie_install_launchd
  elif [ "$LOCAL_MODE" = true ]; then
    log "Local mode: Roadie installed. Run manually with:"
    log "  cd $SITE_PATH && $(_roadie_manual_command)"
  else
    _roadie_install_systemd
  fi

  [ "${EXTERNAL_WORDPRESS:-false}" != true ] || return 0
  _roadie_register_cli_channel
}

_roadie_manual_command() {
  printf 'ROADIE_MANAGED=1 ROADIE_PROMPT_CONFIG=%s ROADIE_SERVICE_TOKEN_FILE=%s roadie --data-dir %s' \
    "$(_roadie_shell_quote "$(roadie_prompt_config_file)")" \
    "$(_roadie_shell_quote "$(_roadie_send_token_file)")" \
    "$(_roadie_shell_quote "$ROADIE_DATA_DIR")"
}

# Register `roadie send` with the wp-coding-agents CLI transport so that
# `agents/dispatch-message` can deliver to a Discord channel. The transport
# runs as the web user, which cannot open the Roadie data dir; Roadie then
# posts to the running bot with the send token instead.
_roadie_register_cli_channel() {
  local env_json
  env_json=$(python3 - "$(_roadie_send_token_file)" "${ROADIE_DATA_DIR:-}" "${ROADIE_LOCK_PORT:-}" <<'PY'
import json, sys
token_file, data_dir, lock_port = sys.argv[1:4]
env = {"ROADIE_SERVICE_TOKEN_FILE": token_file, "HOME": "/tmp"}
if data_dir:
    env["ROADIE_DATA_DIR"] = data_dir
if lock_port:
    env["ROADIE_LOCK_PORT"] = lock_port
print(json.dumps(env, separators=(",", ":")))
PY
)
  cli_channel_register \
    "roadie" \
    "$(roadie_bin)" \
    '["send","--channel","{recipient}","--prompt","{message}"]' \
    "600" \
    "$env_json"
}

_roadie_path_value() {
  local roadie_bin_dir node_bin_dir homeboy_bin_dir=""
  roadie_bin_dir=$(dirname "$ROADIE_BIN")
  node_bin_dir=$(_resolve_node_bin_dir "$ROADIE_BIN")
  if [ "${LOCAL_MODE:-false}" != true ] && [ "${EXTERNAL_WORDPRESS:-false}" != true ] \
     && [ -n "${SERVICE_USER:-}" ] && [ "$SERVICE_USER" != root ]; then
    homeboy_bin_dir="$(dirname "${WP_CODING_AGENTS_HOMEBOY_MANAGED_BIN:-/usr/local/lib/wp-coding-agents/bin/homeboy}")"
  fi
  _compose_path_value "$homeboy_bin_dir" "$roadie_bin_dir" "$node_bin_dir" /usr/local/bin /usr/bin /bin
}

# Environment every Roadie service carries. Secrets are file references.
_roadie_template_env() {
  local path_value="$1"
  cat <<EOF
Environment=HOME=$SERVICE_HOME
Environment=PATH=$path_value
Environment=ROADIE_DATA_DIR=$ROADIE_DATA_DIR
Environment=ROADIE_MANAGED=1
Environment=ROADIE_NO_DEFAULT_CHANNEL=1
Environment=ROADIE_PROMPT_CONFIG=$(roadie_prompt_config_file)
Environment=ROADIE_PLUGINS=$(roadie_plugins_value)
Environment=ROADIE_SERVICE_TOKEN_FILE=$(_roadie_send_token_file)
Environment=DATAMACHINE_SITE_PATH=$SITE_PATH
$(_roadie_datamachine_wp_transport_systemd_env)
EOF
  if [ -s "$(_roadie_bot_token_file)" ] || [ -n "${ROADIE_BOT_TOKEN:-}" ]; then
    echo "Environment=ROADIE_BOT_TOKEN_FILE=$(_roadie_bot_token_file)"
  fi
  if [ -n "${ROADIE_LOCK_PORT:-}" ]; then
    echo "Environment=ROADIE_LOCK_PORT=$ROADIE_LOCK_PORT"
  fi
  if [ -n "${AGENT_SLUG:-}" ]; then
    echo "Environment=DATAMACHINE_AGENT_SLUG=$AGENT_SLUG"
  fi
}

_roadie_append_env_files() {
  local env_block="$1"
  if declare -F ai_gateway_enabled_for_opencode >/dev/null && ai_gateway_enabled_for_opencode; then
    local gateway_env_line="EnvironmentFile=-$(ai_gateway_env_file)"
    grep -qF "$gateway_env_line" <<< "$env_block" || env_block="$env_block
$gateway_env_line"
  fi
  if declare -F codebox_database_enabled >/dev/null && codebox_database_enabled; then
    local codebox_db_env_line="EnvironmentFile=-$CODEBOX_DATABASE_ENV_FILE"
    grep -qF "$codebox_db_env_line" <<< "$env_block" || env_block="$env_block
$codebox_db_env_line"
  fi
  printf '%s\n' "$env_block"
}

_roadie_install_systemd() {
  local unit_dir env_block
  unit_dir="$(_roadie_unit_dir)"
  env_block="$(_roadie_append_env_files "$(_roadie_template_env "$(_roadie_path_value)")")"
  write_file "$unit_dir/$ROADIE_UNIT" "$(bridge_render_systemd "$ROADIE_UNIT" "$env_block")"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable "$ROADIE_UNIT"
}

_roadie_install_launchd() {
  local label="com.wp.roadie" plist_dir="$HOME/Library/LaunchAgents"
  local plist="$plist_dir/$label.plist"
  run_cmd mkdir -p "$ROADIE_DATA_DIR" "$plist_dir"
  write_file "$plist" "$(bridge_render_launchd "$label")"

  if [ "$DRY_RUN" = false ] && bridge_is_ready; then
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    log "Roadie launchd service installed and started"
  elif [ "$DRY_RUN" = false ]; then
    log "No Discord bot token yet — service not started. Run onboarding, then enable it:"
    log "  cd $SITE_PATH && $(_roadie_manual_command)"
    log "  launchctl bootstrap gui/$(id -u) $plist"
  fi
}

# ============================================================================
# Upgrade-time config sync (Phase 2)
# ============================================================================

bridge_sync_config() {
  log "Phase 2: Syncing Roadie config ($(roadie_config_dir))..."
  _roadie_provision_package
  ROADIE_BIN="$(roadie_bin)"
  _roadie_install_secrets
  _roadie_sync_assets
  [ "${EXTERNAL_WORDPRESS:-false}" != true ] && _roadie_register_cli_channel
  log "  Done."
  RESOLVED_ROADIE_CONFIG_DIR="$(roadie_config_dir)"
  RESOLVED_ROADIE_PLUGINS_DIR="$(bridge_managed_plugins_dir)"
}

# ============================================================================
# Upgrade-time service refresh (Phase 5)
# ============================================================================

bridge_update_systemd() {
  log "Phase 5: Checking $ROADIE_UNIT template..."
  local unit_file
  unit_file="$(_roadie_unit_dir)/$ROADIE_UNIT"
  if [ ! -f "$unit_file" ]; then
    if [ -n "$(_roadie_kimaki_unit || true)" ]; then
      log "  $ROADIE_UNIT missing but a Kimaki unit exists — migrating"
      bridge_install
      return 0
    fi
    warn "  $unit_file does not exist — skipping"
    return 0
  fi

  ROADIE_BIN="$(roadie_bin)"
  local path_value current_env merged_env
  path_value="$(_roadie_path_value)"
  current_env=$(grep '^Environment=' "$unit_file" || true)
  local key
  for key in DATAMACHINE_WP_CMD DATAMACHINE_WP_TRANSPORT_JSON ROADIE_BOT_TOKEN; do
    current_env=$(_roadie_remove_systemd_env_key "$current_env" "$key")
  done
  [ "${ROADIE_DATA_DIR_EXPLICIT:-false}" != true ] || current_env=$(_roadie_remove_systemd_env_key "$current_env" ROADIE_DATA_DIR)
  [ "${ROADIE_LOCK_PORT_EXPLICIT:-false}" != true ] || current_env=$(_roadie_remove_systemd_env_key "$current_env" ROADIE_LOCK_PORT)
  [ "${AGENT_SLUG_EXPLICIT:-false}" != true ] || current_env=$(_roadie_remove_systemd_env_key "$current_env" DATAMACHINE_AGENT_SLUG)
  current_env=$(_ensure_systemd_path_contains "$current_env" "$(dirname "$ROADIE_BIN")")

  merged_env=$(_merge_systemd_env_lines "$current_env" "$(_roadie_template_env "$path_value")")
  merged_env=$(_preserve_systemd_umask "$unit_file" "$merged_env")
  merged_env=$(_roadie_append_env_files "$merged_env")

  _smart_update_systemd_unit "$unit_file" "$(bridge_render_systemd "$ROADIE_UNIT" "$merged_env")" "$ROADIE_UNIT"
}

bridge_update_launchd() {
  log "Phase 5a: Checking com.wp.roadie launchd template..."
  local plist="$HOME/Library/LaunchAgents/com.wp.roadie.plist"
  if [ ! -f "$plist" ]; then
    if [ -f "$HOME/Library/LaunchAgents/com.wp.kimaki.plist" ]; then
      log "  com.wp.roadie missing but com.wp.kimaki exists — migrating"
      bridge_install
      return 0
    fi
    warn "  $plist does not exist — skipping"
    return 0
  fi

  ROADIE_BIN="$(roadie_bin)"
  local new_plist
  new_plist=$(bridge_render_launchd com.wp.roadie)
  if echo "$new_plist" | cmp -s - "$plist"; then
    log "  com.wp.roadie.plist: unchanged"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would update $plist"
    return 0
  fi
  cp "$plist" "${plist}.backup.$TIMESTAMP"
  echo "$new_plist" > "$plist"
  log "  Updated $plist (backup: ${plist}.backup.$TIMESTAMP)"
  log "  NOTE: com.wp.roadie NOT restarted — run the restart command in the summary when ready"
  UPDATED_ITEMS+=("com.wp.roadie.plist (not restarted)")
}

# ============================================================================
# Templates: systemd unit + launchd plist
# ============================================================================

bridge_render_systemd() {
  local unit="$1" env_block="$2"
  local normalized_unit
  normalized_unit=$(_roadie_normalize_unit_name "$unit")
  [ "$normalized_unit" = "$unit" ] || { echo "roadie has no unit '$unit'" >&2; return 1; }
  _roadie_validate_lock_port

  # The lock port is part of instance identity: two instances on one port
  # evict each other. Re-assert it even if the caller's env block lost it.
  if [ -n "${ROADIE_LOCK_PORT:-}" ] && \
     ! printf '%s\n' "$env_block" | grep -q '^Environment=ROADIE_LOCK_PORT='; then
    env_block="$env_block
Environment=ROADIE_LOCK_PORT=$ROADIE_LOCK_PORT"
  fi

  cat <<EOF
[Unit]
Description=Roadie Discord bridge (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
# Roadie stops its own orphaned agent server on start, resumes runs a restart
# interrupted, and never upgrades itself (ROADIE_MANAGED=1). SIGTERM stops it
# within 15s; SIGUSR2 restarts it in place.
ExecStart=$ROADIE_BIN --data-dir $ROADIE_DATA_DIR --auto-restart
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

bridge_render_launchd() {
  local label="$1"
  [ "$label" = "com.wp.roadie" ] || { echo "roadie has no label '$label'" >&2; return 1; }
  local roadie_bin_dir node_bin_dir path_value datamachine_wp_transport_json
  roadie_bin_dir="$(dirname "$ROADIE_BIN")"
  node_bin_dir="$(_resolve_node_bin_dir "$ROADIE_BIN")"
  path_value="$(_compose_path_value "$HOME/.local/bin" "$roadie_bin_dir" "$node_bin_dir" "$HOME/.opencode/bin" "$HOME/.bun/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)"
  datamachine_wp_transport_json=$(xml_escape "$(_roadie_datamachine_wp_transport_json)")
  plist_document <<EOF
    <key>Label</key>
    <string>$(xml_escape "$label")</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$ROADIE_BIN")</string>
        <string>--data-dir</string>
        <string>$(xml_escape "$ROADIE_DATA_DIR")</string>
        <string>--auto-restart</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xml_escape "$SITE_PATH")</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$ROADIE_DATA_DIR/roadie.stdout.log")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$ROADIE_DATA_DIR/roadie.stderr.log")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xml_escape "$path_value")</string>
        <key>ROADIE_DATA_DIR</key>
        <string>$(xml_escape "$ROADIE_DATA_DIR")</string>
        <key>ROADIE_MANAGED</key>
        <string>1</string>
        <key>ROADIE_NO_DEFAULT_CHANNEL</key>
        <string>1</string>
        <key>ROADIE_PROMPT_CONFIG</key>
        <string>$(xml_escape "$(roadie_prompt_config_file)")</string>
        <key>ROADIE_PLUGINS</key>
        <string>$(xml_escape "$(roadie_plugins_value)")</string>
        <key>ROADIE_SERVICE_TOKEN_FILE</key>
        <string>$(xml_escape "$(_roadie_send_token_file)")</string>
        <key>DATAMACHINE_SITE_PATH</key>
        <string>$(xml_escape "$SITE_PATH")</string>
        <key>DATAMACHINE_WP_TRANSPORT_JSON</key>
        <string>$datamachine_wp_transport_json</string>$(if [ -s "$(_roadie_bot_token_file)" ] || [ -n "${ROADIE_BOT_TOKEN:-}" ]; then echo "
        <key>ROADIE_BOT_TOKEN_FILE</key>
        <string>$(xml_escape "$(_roadie_bot_token_file)")</string>"; fi)$(if [ -n "${AGENT_SLUG:-}" ]; then echo "
        <key>DATAMACHINE_AGENT_SLUG</key>
        <string>$(xml_escape "$AGENT_SLUG")</string>"; fi)$(_roadie_ai_gateway_launchd_env_xml)
    </dict>
EOF
}

_roadie_datamachine_wp_transport_json() {
  if [ "${EXTERNAL_WORDPRESS:-false}" = true ]; then
    python3 - "$(external_wordpress_control_command)" <<'PY'
import json, sys
print(json.dumps(sys.argv[1:], separators=(",", ":")))
PY
    return 0
  fi
  wp_cli_transport_json
}

_roadie_datamachine_wp_transport_systemd_env() {
  local value
  value=$(_roadie_datamachine_wp_transport_json)
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf 'Environment=DATAMACHINE_WP_TRANSPORT_JSON="%s"\n' "$value"
}

_roadie_ai_gateway_launchd_env_xml() {
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
        <string>$(xml_escape "$base_url")</string>"
  if [ -n "$api_key" ]; then
    echo "        <key>OPENAI_API_KEY</key>
        <string>$(xml_escape "$api_key")</string>"
  fi
}

# ============================================================================
# Human-facing command accessors
# ============================================================================

bridge_restart_cmd() {
  local env="$1"
  case "$env" in
    local-launchd) echo "launchctl kickstart -k gui/$(id -u)/com.wp.roadie" ;;
    local-manual)  echo "cd $SITE_PATH && $(_roadie_manual_command)" ;;
    vps)           echo "systemctl restart ${ROADIE_UNIT:-roadie.service}" ;;
    *)
      echo "bridge_restart_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_verify_cmd() {
  local env="$1" port="${ROADIE_LOCK_PORT:-29988}"
  case "$env" in
    local-launchd) echo "launchctl print gui/$(id -u)/com.wp.roadie | head -20" ;;
    local-manual)  echo "pgrep -fl roadie" ;;
    vps)           echo "systemctl status ${ROADIE_UNIT:-roadie.service} && curl -fsS http://127.0.0.1:$port/health" ;;
    *)
      echo "bridge_verify_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_logs_cmd() {
  if [ "${LOCAL_MODE:-false}" = true ]; then
    echo "tail -f $ROADIE_DATA_DIR/roadie.log"
  else
    echo "journalctl -u ${ROADIE_UNIT:-roadie.service} -f"
  fi
}

bridge_start_hint() {
  local env="$1"
  case "$env" in
    local-launchd) echo "launchctl kickstart gui/$(id -u)/com.wp.roadie" ;;
    local-manual)  bridge_restart_cmd local-manual ;;
    vps)           echo "systemctl start ${ROADIE_UNIT:-roadie.service}" ;;
    *)
      echo "bridge_start_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

bridge_stop_hint() {
  local env="$1"
  case "$env" in
    local-launchd) echo "launchctl kill SIGTERM gui/$(id -u)/com.wp.roadie" ;;
    vps)           echo "systemctl stop ${ROADIE_UNIT:-roadie.service}" ;;
    local-manual)  ;;
    *)
      echo "bridge_stop_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}

# ============================================================================
# Summary blocks (lib/summary.sh next-steps prose)
# ============================================================================

bridge_vps_setup_block() {
  echo "  1. Set up the Discord bot token (create a bot at https://discord.com/developers/applications):"
  echo "       Rerun setup with ROADIE_BOT_TOKEN=<token>, or write it to $(_roadie_bot_token_file)"
  echo "       (mode 0600, owned by ${SERVICE_USER:-the service user})."
  echo ""
  echo "  2. Start the agent:  systemctl start ${ROADIE_UNIT:-roadie.service}"
}

bridge_launchd_setup_block() {
  echo "  Roadie setup:"
  echo "    1. Run onboarding:  cd $SITE_PATH && $(_roadie_manual_command)"
  echo "    2. Enable service:  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.wp.roadie.plist"
}

bridge_vps_start_preamble() {
  echo "  Bot token configured ($(_roadie_bot_token_file) or saved Roadie credentials)."
}

bridge_verify_extra() {
  local plugins_dir
  plugins_dir="$(bridge_managed_plugins_dir)"
  echo "test -f $plugins_dir/dm-agent-sync.ts && test -f $(roadie_prompt_config_file)   # managed config installed"
  echo "test -x $(roadie_bin)   # Roadie $(roadie_pinned_version) installed"
}
