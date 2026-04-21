#!/bin/bash
# lib/chat-bridges.sh — single source of truth for chat-bridge identity + templates.
#
# Registry of metadata and template generators for every supported chat bridge
# (kimaki, cc-connect, telegram). Both install-time (setup.sh via
# lib/chat-bridge.sh) and upgrade-time (upgrade.sh Phase 5) consume the same
# generators here so systemd units and launchd plists never drift between the
# two paths (see #48).
#
# Bash 3.2 compatible — macOS default shell. No associative arrays. All data
# access goes through case-based accessor functions.
#
# ---------------------------------------------------------------------------
# Surface
# ---------------------------------------------------------------------------
#   Registry:
#     bridge_names                     List supported bridges (space-sep).
#     bridge_systemd_units <b>         Unit file names for bridge <b>.
#     bridge_launchd_labels <b>        Plist labels for bridge <b>.
#     bridge_binaries <b>              Binaries the bridge needs on PATH.
#
#   Detection:
#     bridge_detect_local              Prints detected bridge name or empty.
#     bridge_detect_vps                Prints detected bridge name or empty.
#
#   Template generators:
#     bridge_render_systemd <b> <unit> <merged_env>   Emit full unit file.
#     bridge_render_launchd <b> <label>               Emit full plist XML.
#
#   Human-facing command accessors (consumed by summary + upgrade hints):
#     bridge_restart_cmd <b> <env>     "systemctl restart …" or launchctl lines.
#     bridge_verify_cmd <b> <env>      Status inspection command(s).
#     bridge_logs_cmd <b>              tail -f path(s).
#     bridge_start_hint <b> <env>      First-run start command(s).
#
# ---------------------------------------------------------------------------
# Caller contract — template generators expect these globals to be set
# (same as the existing _install_*_systemd / _install_*_launchd functions):
#
#   SERVICE_USER, SERVICE_HOME, SITE_PATH             — all bridges
#   KIMAKI_BIN, KIMAKI_CONFIG_DIR, KIMAKI_DATA_DIR    — kimaki
#   KIMAKI_BOT_TOKEN                                  — kimaki (optional)
#   CC_BIN, CC_DATA_DIR                               — cc-connect
#   CC_CONNECT_TOKEN                                  — cc-connect (optional)
#   OPENCODE_BIN, TELEGRAM_BIN                        — telegram
#   SERVE_ENV_FILE, TELEGRAM_CONFIG_DIR               — telegram
#   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USER_ID      — telegram (optional)
#   OPENCODE_MODEL                                    — telegram (optional)
#
# These are per-install values resolved by detect_environment + setup.sh and
# are not owned by this file.
# ---------------------------------------------------------------------------

# ===========================================================================
# Registry — bridge identity data
# ===========================================================================

bridge_names() {
  echo "kimaki cc-connect telegram"
}

bridge_systemd_units() {
  case "$1" in
    kimaki)     echo "kimaki.service" ;;
    cc-connect) echo "cc-connect.service" ;;
    telegram)   echo "opencode-serve.service opencode-telegram.service" ;;
    *) return 1 ;;
  esac
}

bridge_launchd_labels() {
  case "$1" in
    kimaki)     echo "com.wp.kimaki" ;;
    cc-connect) echo "com.wp.cc-connect" ;;
    telegram)   echo "com.wp.opencode-serve com.wp.opencode-telegram" ;;
    *) return 1 ;;
  esac
}

# Primary binary first; additional binaries space-separated. Used for
# `command -v` fallback detection on local installs.
bridge_binaries() {
  case "$1" in
    kimaki)     echo "kimaki" ;;
    cc-connect) echo "cc-connect" ;;
    telegram)   echo "opencode-telegram opencode" ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# Detection — returns first matching bridge name on stdout, or empty
# ===========================================================================

# Local: a bridge is "present" if ANY of its launchd plists exist or ANY of
# its binaries are on PATH. Multi-service bridges (telegram) install a pair
# of plists — either one signals presence.
# Priority order matches setup.sh: kimaki > cc-connect > telegram.
bridge_detect_local() {
  local bridge label bin
  for bridge in $(bridge_names); do
    for label in $(bridge_launchd_labels "$bridge"); do
      if [ -f "$HOME/Library/LaunchAgents/${label}.plist" ]; then
        echo "$bridge"
        return 0
      fi
    done
    for bin in $(bridge_binaries "$bridge"); do
      if command -v "$bin" >/dev/null 2>&1; then
        echo "$bridge"
        return 0
      fi
    done
  done
  return 0
}

# VPS: a bridge is "present" if ANY of its systemd unit files exist.
bridge_detect_vps() {
  local bridge unit
  for bridge in $(bridge_names); do
    for unit in $(bridge_systemd_units "$bridge"); do
      if [ -f "/etc/systemd/system/${unit}" ]; then
        echo "$bridge"
        return 0
      fi
    done
  done
  return 0
}

# ===========================================================================
# Template generators — systemd unit files
# ===========================================================================

# bridge_render_systemd <bridge> <unit-name> <merged-env-block>
#
# Emits the full unit file to stdout. <merged-env-block> is the set of
# `Environment=KEY=VALUE` lines (already merged by the caller, if upgrading
# an existing unit file — see upgrade.sh::_merge_systemd_env_lines).
bridge_render_systemd() {
  local bridge="$1" unit="$2" env_block="$3"
  case "$bridge" in
    kimaki)
      _render_systemd_kimaki "$unit" "$env_block" ;;
    cc-connect)
      _render_systemd_cc_connect "$unit" "$env_block" ;;
    telegram)
      _render_systemd_telegram "$unit" "$env_block" ;;
    *)
      echo "bridge_render_systemd: unknown bridge '$bridge'" >&2
      return 1 ;;
  esac
}

_render_systemd_kimaki() {
  local unit="$1" env_block="$2"
  [ "$unit" = "kimaki.service" ] || { echo "kimaki has no unit '$unit'" >&2; return 1; }
  cat <<EOF
[Unit]
Description=Kimaki Discord Bot (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
ExecStartPre=$KIMAKI_CONFIG_DIR/post-upgrade.sh
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

_render_systemd_cc_connect() {
  local unit="$1" env_block="$2"
  [ "$unit" = "cc-connect.service" ] || { echo "cc-connect has no unit '$unit'" >&2; return 1; }
  cat <<EOF
[Unit]
Description=cc-connect Chat Bridge (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
ExecStart=$CC_BIN
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

_render_systemd_telegram() {
  local unit="$1" env_block="$2"
  case "$unit" in
    opencode-serve.service)
      cat <<EOF
[Unit]
Description=OpenCode Server (wp-coding-agents)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
EnvironmentFile=-$SERVE_ENV_FILE
ExecStart=$OPENCODE_BIN serve
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
    opencode-telegram.service)
      cat <<EOF
[Unit]
Description=OpenCode Telegram Bot (wp-coding-agents)
After=network.target opencode-serve.service
Requires=opencode-serve.service

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$env_block
EnvironmentFile=$TELEGRAM_CONFIG_DIR/.env
ExecStart=$TELEGRAM_BIN start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
    *)
      echo "telegram has no unit '$unit'" >&2
      return 1 ;;
  esac
}

# ===========================================================================
# Template generators — launchd plists
# ===========================================================================

# bridge_render_launchd <bridge> <plist-label>
#
# Emits the full plist XML to stdout. Multi-service bridges (telegram) pick
# the plist matching <plist-label>.
bridge_render_launchd() {
  local bridge="$1" label="$2"
  case "$bridge" in
    kimaki)
      _render_launchd_kimaki "$label" ;;
    cc-connect)
      _render_launchd_cc_connect "$label" ;;
    telegram)
      _render_launchd_telegram "$label" ;;
    *)
      echo "bridge_render_launchd: unknown bridge '$bridge'" >&2
      return 1 ;;
  esac
}

_render_launchd_kimaki() {
  local label="$1"
  [ "$label" = "com.wp.kimaki" ] || { echo "kimaki has no label '$label'" >&2; return 1; }
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$KIMAKI_BIN</string>
        <string>--data-dir</string>
        <string>$KIMAKI_DATA_DIR</string>
        <string>--auto-restart</string>
        <string>--no-critique</string>
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
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>KIMAKI_DATA_DIR</key>
        <string>$KIMAKI_DATA_DIR</string>$(if [ -n "${KIMAKI_BOT_TOKEN:-}" ]; then echo "
        <key>KIMAKI_BOT_TOKEN</key>
        <string>$KIMAKI_BOT_TOKEN</string>"; fi)
    </dict>
</dict>
</plist>
EOF
}

_render_launchd_cc_connect() {
  local label="$1"
  [ "$label" = "com.wp.cc-connect" ] || { echo "cc-connect has no label '$label'" >&2; return 1; }
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CC_BIN</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CC_DATA_DIR/cc-connect.log</string>
    <key>StandardErrorPath</key>
    <string>$CC_DATA_DIR/cc-connect.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF
}

_render_launchd_telegram() {
  local label="$1"
  local log_dir="$TELEGRAM_CONFIG_DIR"
  case "$label" in
    com.wp.opencode-serve)
      cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$OPENCODE_BIN</string>
        <string>serve</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/opencode-serve.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/opencode-serve.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>$(if [ -n "${OPENCODE_MODEL:-}" ]; then echo "
        <key>OPENCODE_MODEL</key>
        <string>$OPENCODE_MODEL</string>"; fi)
    </dict>
</dict>
</plist>
EOF
      ;;
    com.wp.opencode-telegram)
      cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TELEGRAM_BIN</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SITE_PATH</string>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/opencode-telegram.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/opencode-telegram.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$SERVICE_HOME</string>$(if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "
        <key>TELEGRAM_BOT_TOKEN</key>
        <string>$TELEGRAM_BOT_TOKEN</string>"; fi)$(if [ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]; then echo "
        <key>TELEGRAM_ALLOWED_USER_ID</key>
        <string>$TELEGRAM_ALLOWED_USER_ID</string>"; fi)
        <key>OPENCODE_API_URL</key>
        <string>http://localhost:4096</string>
    </dict>
</dict>
</plist>
EOF
      ;;
    *)
      echo "telegram has no label '$label'" >&2
      return 1 ;;
  esac
}

# ===========================================================================
# Human-facing command accessors
# ===========================================================================

# bridge_restart_cmd <bridge> <env>    env = local-launchd | local-manual | vps
#
# Emits one restart instruction per line. Multi-service bridges emit multiple
# lines. Caller is responsible for any surrounding prose.
bridge_restart_cmd() {
  local bridge="$1" env="$2" label units uid
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in $(bridge_launchd_labels "$bridge"); do
        echo "launchctl kickstart -k gui/${uid}/${label}"
      done
      ;;
    local-manual)
      case "$bridge" in
        kimaki)     echo "cd $SITE_PATH && kimaki" ;;
        cc-connect) echo "cd $SITE_PATH && cc-connect" ;;
        telegram)
          echo "cd $SITE_PATH && opencode serve &"
          echo "opencode-telegram start"
          ;;
      esac
      ;;
    vps)
      units=$(bridge_systemd_units "$bridge" | sed 's/\.service//g')
      # shellcheck disable=SC2086
      echo "systemctl restart $units"
      ;;
    *)
      echo "bridge_restart_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

# bridge_verify_cmd <bridge> <env>    env = local-launchd | local-manual | vps
#
# Emits one verify/status command per line.
bridge_verify_cmd() {
  local bridge="$1" env="$2" label units uid primary
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in $(bridge_launchd_labels "$bridge"); do
        echo "launchctl print gui/${uid}/${label} | head -20"
      done
      ;;
    local-manual)
      primary=$(bridge_binaries "$bridge" | awk '{print $1}')
      echo "pgrep -fl ${primary}"
      ;;
    vps)
      units=$(bridge_systemd_units "$bridge" | sed 's/\.service//g')
      # shellcheck disable=SC2086
      echo "systemctl status $units"
      ;;
    *)
      echo "bridge_verify_cmd: unknown env '$env'" >&2
      return 1 ;;
  esac
}

# bridge_logs_cmd <bridge>  — tail -f recipe(s). Uses the same caller globals
# as the template generators.
bridge_logs_cmd() {
  case "$1" in
    kimaki)
      echo "tail -f $KIMAKI_DATA_DIR/kimaki.log"
      ;;
    cc-connect)
      echo "tail -f ${CC_DATA_DIR:-$SERVICE_HOME/.cc-connect}/cc-connect.log"
      ;;
    telegram)
      echo "tail -f $TELEGRAM_CONFIG_DIR/opencode-serve.log"
      echo "tail -f $TELEGRAM_CONFIG_DIR/opencode-telegram.log"
      ;;
    *) return 1 ;;
  esac
}

# bridge_start_hint <bridge> <env>   env = local-launchd | local-manual | vps
#
# First-run start instruction for summary output. Single-line where sensible,
# multi-line for multi-service bridges.
bridge_start_hint() {
  local bridge="$1" env="$2" label units uid
  uid=$(id -u)
  case "$env" in
    local-launchd)
      for label in $(bridge_launchd_labels "$bridge"); do
        echo "launchctl kickstart gui/${uid}/${label}"
      done
      ;;
    local-manual)
      bridge_restart_cmd "$bridge" local-manual
      ;;
    vps)
      units=$(bridge_systemd_units "$bridge" | sed 's/\.service//g')
      # shellcheck disable=SC2086
      echo "systemctl start $units"
      ;;
    *)
      echo "bridge_start_hint: unknown env '$env'" >&2
      return 1 ;;
  esac
}
